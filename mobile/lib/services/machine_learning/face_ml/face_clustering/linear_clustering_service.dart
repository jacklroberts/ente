import "dart:async";
import "dart:developer";
import "dart:isolate";
import "dart:math" show max;
import "dart:typed_data";

import "package:logging/logging.dart";
import "package:photos/generated/protos/ente/common/vector.pb.dart";
import 'package:photos/services/machine_learning/face_ml/face_clustering/cosine_distance.dart';
import "package:photos/services/machine_learning/face_ml/face_ml_result.dart";
import "package:synchronized/synchronized.dart";

class FaceInfo {
  final String faceID;
  final List<double> embedding;
  int? clusterId;
  String? closestFaceId;
  int? closestDist;
  int? fileCreationTime;
  FaceInfo({
    required this.faceID,
    required this.embedding,
    this.clusterId,
    this.fileCreationTime,
  });
}

enum ClusterOperation { linearIncrementalClustering }

class FaceLinearClustering {
  final _logger = Logger("FaceLinearClustering");

  Timer? _inactivityTimer;
  final Duration _inactivityDuration = const Duration(seconds: 30);
  int _activeTasks = 0;

  final _initLock = Lock();

  late Isolate _isolate;
  late ReceivePort _receivePort = ReceivePort();
  late SendPort _mainSendPort;

  bool isSpawned = false;
  bool isRunning = false;

  static const recommendedDistanceThreshold = 0.3;

  // singleton pattern
  FaceLinearClustering._privateConstructor();

  /// Use this instance to access the FaceClustering service.
  /// e.g. `FaceLinearClustering.instance.predict(dataset)`
  static final instance = FaceLinearClustering._privateConstructor();
  factory FaceLinearClustering() => instance;

  Future<void> init() async {
    return _initLock.synchronized(() async {
      if (isSpawned) return;

      _receivePort = ReceivePort();

      try {
        _isolate = await Isolate.spawn(
          _isolateMain,
          _receivePort.sendPort,
        );
        _mainSendPort = await _receivePort.first as SendPort;
        isSpawned = true;

        _resetInactivityTimer();
      } catch (e) {
        _logger.severe('Could not spawn isolate', e);
        isSpawned = false;
      }
    });
  }

  Future<void> ensureSpawned() async {
    if (!isSpawned) {
      await init();
    }
  }

  /// The main execution function of the isolate.
  static void _isolateMain(SendPort mainSendPort) async {
    final receivePort = ReceivePort();
    mainSendPort.send(receivePort.sendPort);

    receivePort.listen((message) async {
      final functionIndex = message[0] as int;
      final function = ClusterOperation.values[functionIndex];
      final args = message[1] as Map<String, dynamic>;
      final sendPort = message[2] as SendPort;

      try {
        switch (function) {
          case ClusterOperation.linearIncrementalClustering:
            final input = args['input'] as Map<String, (int?, Uint8List)>;
            final fileIDToCreationTime =
                args['fileIDToCreationTime'] as Map<int, int>?;
            final result = FaceLinearClustering._runLinearClustering(
              input,
              fileIDToCreationTime: fileIDToCreationTime,
            );
            sendPort.send(result);
            break;
        }
      } catch (e, stackTrace) {
        sendPort
            .send({'error': e.toString(), 'stackTrace': stackTrace.toString()});
      }
    });
  }

  /// The common method to run any operation in the isolate. It sends the [message] to [_isolateMain] and waits for the result.
  Future<dynamic> _runInIsolate(
    (ClusterOperation, Map<String, dynamic>) message,
  ) async {
    await ensureSpawned();
    _resetInactivityTimer();
    final completer = Completer<dynamic>();
    final answerPort = ReceivePort();

    _activeTasks++;
    _mainSendPort.send([message.$1.index, message.$2, answerPort.sendPort]);

    answerPort.listen((receivedMessage) {
      if (receivedMessage is Map && receivedMessage.containsKey('error')) {
        // Handle the error
        final errorMessage = receivedMessage['error'];
        final errorStackTrace = receivedMessage['stackTrace'];
        final exception = Exception(errorMessage);
        final stackTrace = StackTrace.fromString(errorStackTrace);
        _activeTasks--;
        completer.completeError(exception, stackTrace);
      } else {
        _activeTasks--;
        completer.complete(receivedMessage);
      }
    });

    return completer.future;
  }

  /// Resets a timer that kills the isolate after a certain amount of inactivity.
  ///
  /// Should be called after initialization (e.g. inside `init()`) and after every call to isolate (e.g. inside `_runInIsolate()`)
  void _resetInactivityTimer() {
    _inactivityTimer?.cancel();
    _inactivityTimer = Timer(_inactivityDuration, () {
      if (_activeTasks > 0) {
        _logger.info('Tasks are still running. Delaying isolate disposal.');
        // Optionally, reschedule the timer to check again later.
        _resetInactivityTimer();
      } else {
        _logger.info(
          'Clustering Isolate has been inactive for ${_inactivityDuration.inSeconds} seconds with no tasks running. Killing isolate.',
        );
        dispose();
      }
    });
  }

  /// Disposes the isolate worker.
  void dispose() {
    if (!isSpawned) return;

    isSpawned = false;
    _isolate.kill();
    _receivePort.close();
    _inactivityTimer?.cancel();
  }

  /// Runs the clustering algorithm on the given [input], in an isolate.
  ///
  /// Returns the clustering result, which is a list of clusters, where each cluster is a list of indices of the dataset.
  ///
  /// WARNING: Make sure to always input data in the same ordering, otherwise the clustering can less less deterministic.
  Future<Map<String, int>?> predict(
    Map<String, (int?, Uint8List)> input, {
    Map<int, int>? fileIDToCreationTime,
  }) async {
    if (input.isEmpty) {
      _logger.warning(
        "Clustering dataset of embeddings is empty, returning empty list.",
      );
      return null;
    }
    if (isRunning) {
      _logger.warning("Clustering is already running, returning empty list.");
      return null;
    }

    isRunning = true;

    // Clustering inside the isolate
    _logger.info(
      "Start clustering on ${input.length} embeddings inside computer isolate",
    );
    final stopwatchClustering = Stopwatch()..start();
    // final Map<String, int> faceIdToCluster =
    //     await _runLinearClusteringInComputer(input);
    final Map<String, int> faceIdToCluster = await _runInIsolate(
      (
        ClusterOperation.linearIncrementalClustering,
        {'input': input, 'fileIDToCreationTime': fileIDToCreationTime}
      ),
    );
    // return _runLinearClusteringInComputer(input);
    _logger.info(
      'Clustering executed in ${stopwatchClustering.elapsed.inSeconds} seconds',
    );

    isRunning = false;

    return faceIdToCluster;
  }

  static Map<String, int> _runLinearClustering(
    Map<String, (int?, Uint8List)> x, {
    Map<int, int>? fileIDToCreationTime,
  }) {
    log(
      "[ClusterIsolate] ${DateTime.now()} Copied to isolate ${x.length} faces",
    );

    // Organize everything into a list of FaceInfo objects
    final List<FaceInfo> faceInfos = [];
    for (final entry in x.entries) {
      faceInfos.add(
        FaceInfo(
          faceID: entry.key,
          embedding: EVector.fromBuffer(entry.value.$2).values,
          clusterId: entry.value.$1,
          fileCreationTime:
              fileIDToCreationTime?[getFileIdFromFaceId(entry.key)],
        ),
      );
    }

    // Sort the faceInfos based on fileCreationTime, in ascending order, so oldest faces are first
    if (fileIDToCreationTime != null) {
      faceInfos.sort((a, b) {
        if (a.fileCreationTime == null && b.fileCreationTime == null) {
          return 0;
        } else if (a.fileCreationTime == null) {
          return 1;
        } else if (b.fileCreationTime == null) {
          return -1;
        } else {
          return a.fileCreationTime!.compareTo(b.fileCreationTime!);
        }
      });
    }

    // Sort the faceInfos such that the ones with null clusterId are at the end
    final List<FaceInfo> facesWithClusterID = <FaceInfo>[];
    final List<FaceInfo> facesWithoutClusterID = <FaceInfo>[];
    for (final FaceInfo faceInfo in faceInfos) {
      if (faceInfo.clusterId == null) {
        facesWithoutClusterID.add(faceInfo);
      } else {
        facesWithClusterID.add(faceInfo);
      }
    }
    final sortedFaceInfos = <FaceInfo>[];
    sortedFaceInfos.addAll(facesWithClusterID);
    sortedFaceInfos.addAll(facesWithoutClusterID);

    log(
      "[ClusterIsolate] ${DateTime.now()} Clustering ${facesWithoutClusterID.length} new faces without clusterId, and ${facesWithClusterID.length} faces with clusterId",
    );

    // Make sure the first face has a clusterId
    final int totalFaces = sortedFaceInfos.length;
    // set current epoch time as clusterID
    int clusterID = DateTime.now().millisecondsSinceEpoch;
    if (sortedFaceInfos.isNotEmpty) {
      if (sortedFaceInfos.first.clusterId == null) {
        sortedFaceInfos.first.clusterId = clusterID;
      } else {
        clusterID = sortedFaceInfos.first.clusterId!;
      }
    } else {
      return {};
    }

    // Start actual clustering
    log(
      "[ClusterIsolate] ${DateTime.now()} Processing $totalFaces faces",
    );
    final Map<String, int> newFaceIdToCluster = {};
    final stopwatchClustering = Stopwatch()..start();
    for (int i = 1; i < totalFaces; i++) {
      // Incremental clustering, so we can skip faces that already have a clusterId
      if (sortedFaceInfos[i].clusterId != null) {
        clusterID = max(clusterID, sortedFaceInfos[i].clusterId!);
        if (i % 250 == 0) {
          log("[ClusterIsolate] ${DateTime.now()} First $i faces already had a clusterID");
        }
        continue;
      }
      final currentEmbedding = sortedFaceInfos[i].embedding;
      int closestIdx = -1;
      double closestDistance = double.infinity;
      if (i % 250 == 0) {
        log("[ClusterIsolate] ${DateTime.now()} Processing $i faces");
      }
      for (int j = i - 1; j >= 0; j--) {
        final double distance = cosineDistForNormVectors(
          currentEmbedding,
          sortedFaceInfos[j].embedding,
        );
        if (distance < closestDistance) {
          closestDistance = distance;
          closestIdx = j;
        }
      }

      if (closestDistance < recommendedDistanceThreshold) {
        if (sortedFaceInfos[closestIdx].clusterId == null) {
          // Ideally this should never happen, but just in case log it
          log(
            " [ClusterIsolate] [WARNING] ${DateTime.now()} Found new cluster $clusterID",
          );
          clusterID++;
          sortedFaceInfos[closestIdx].clusterId = clusterID;
          newFaceIdToCluster[sortedFaceInfos[closestIdx].faceID] = clusterID;
        }
        sortedFaceInfos[i].clusterId = sortedFaceInfos[closestIdx].clusterId;
        newFaceIdToCluster[sortedFaceInfos[i].faceID] =
            sortedFaceInfos[closestIdx].clusterId!;
      } else {
        clusterID++;
        sortedFaceInfos[i].clusterId = clusterID;
        newFaceIdToCluster[sortedFaceInfos[i].faceID] = clusterID;
      }
    }

    stopwatchClustering.stop();
    log(
      ' [ClusterIsolate] ${DateTime.now()} Clustering for ${sortedFaceInfos.length} embeddings (${sortedFaceInfos[0].embedding.length} size) executed in ${stopwatchClustering.elapsedMilliseconds}ms, clusters $clusterID',
    );

    // analyze the results
    FaceLinearClustering._analyzeClusterResults(sortedFaceInfos);

    return newFaceIdToCluster;
  }

  static void _analyzeClusterResults(List<FaceInfo> sortedFaceInfos) {
    final stopwatch = Stopwatch()..start();

    final Map<String, int> faceIdToCluster = {};
    for (final faceInfo in sortedFaceInfos) {
      faceIdToCluster[faceInfo.faceID] = faceInfo.clusterId!;
    }

    //  Find faceIDs that are part of a cluster which is larger than 5 and are new faceIDs
    final Map<int, int> clusterIdToSize = {};
    faceIdToCluster.forEach((key, value) {
      if (clusterIdToSize.containsKey(value)) {
        clusterIdToSize[value] = clusterIdToSize[value]! + 1;
      } else {
        clusterIdToSize[value] = 1;
      }
    });

    // print top 10 cluster ids and their sizes based on the internal cluster id
    final clusterIds = faceIdToCluster.values.toSet();
    final clusterSizes = clusterIds.map((clusterId) {
      return faceIdToCluster.values.where((id) => id == clusterId).length;
    }).toList();
    clusterSizes.sort();
    // find clusters whose size is greater than 1
    int oneClusterCount = 0;
    int moreThan5Count = 0;
    int moreThan10Count = 0;
    int moreThan20Count = 0;
    int moreThan50Count = 0;
    int moreThan100Count = 0;

    for (int i = 0; i < clusterSizes.length; i++) {
      if (clusterSizes[i] > 100) {
        moreThan100Count++;
      } else if (clusterSizes[i] > 50) {
        moreThan50Count++;
      } else if (clusterSizes[i] > 20) {
        moreThan20Count++;
      } else if (clusterSizes[i] > 10) {
        moreThan10Count++;
      } else if (clusterSizes[i] > 5) {
        moreThan5Count++;
      } else if (clusterSizes[i] == 1) {
        oneClusterCount++;
      }
    }

    // print the metrics
    log(
      "[ClusterIsolate]  Total clusters ${clusterIds.length}: \n oneClusterCount $oneClusterCount \n moreThan5Count $moreThan5Count \n moreThan10Count $moreThan10Count \n moreThan20Count $moreThan20Count \n moreThan50Count $moreThan50Count \n moreThan100Count $moreThan100Count",
    );
    stopwatch.stop();
    log(
      "[ClusterIsolate]  Clustering additional analysis took ${stopwatch.elapsedMilliseconds} ms",
    );
  }
}
