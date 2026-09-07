import 'dart:io';
import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import '../utils/app_logger.dart';
import '../utils/proxy_dio_helper.dart';
import 'storage_service.dart';

class RemoteReleaseInfo {
  final String tagName;
  final String version;
  final String releaseNotes;
  final String assetName;
  final String downloadUrl;
  final int assetSize;
  final DateTime publishedAt;

  /// Optional URL of a SHA256SUMS.txt manifest shipped with the release
  /// (currently only the app's own releases provide one).
  final String? sha256SumsUrl;

  RemoteReleaseInfo({
    required this.tagName,
    required this.version,
    required this.releaseNotes,
    required this.assetName,
    required this.downloadUrl,
    required this.assetSize,
    required this.publishedAt,
    this.sha256SumsUrl,
  });
}

class CoreUpdaterService {
  static const repoApiUrl =
      'https://api.github.com/repos/SagerNet/sing-box/releases/latest';

  final Dio _dio;

  CoreUpdaterService({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 15),
                receiveTimeout: const Duration(seconds: 60),
                headers: {
                  'User-Agent': 'sing-box-ui-updater',
                  'Accept': 'application/vnd.github.v3+json',
                },
              ),
            );

  /// Configures local proxy port for downloading and API calls when core is running.
  void setProxyPort(int? port) {
    ProxyDioHelper.configureProxy(_dio, proxyPort: port);
  }

  /// Check GitHub for the latest sing-box release with proxy support and mirror fallbacks
  Future<RemoteReleaseInfo?> checkLatestRelease() async {
    final apiUrls = [
      repoApiUrl,
      'https://ghproxy.net/$repoApiUrl',
      'https://mirror.ghproxy.com/$repoApiUrl',
    ];

    Map<String, dynamic>? data;
    String? lastError;
    for (final url in apiUrls) {
      try {
        AppLogger.info('[CoreUpdater] 尝试请求 sing-box 版本源: $url');
        final response = await _dio.get<Map<String, dynamic>>(url);
        if (response.data != null && response.data!['tag_name'] != null) {
          data = response.data;
          AppLogger.info('[CoreUpdater] 成功获取内核版本信息，最新标签: ${data!['tag_name']}');
          break;
        }
      } catch (e) {
        lastError = e.toString();
        AppLogger.warn('[CoreUpdater] 请求内核更新源失败 ($url): $e');
      }
    }

    if (data == null) {
      if (lastError != null) {
        AppLogger.error('[CoreUpdater] 所有 sing-box GitHub Release 接口均访问失败: $lastError');
      }
      return null;
    }

    try {
      final tagName = (data['tag_name'] ?? '').toString();
      final version = tagName.startsWith('v') ? tagName.substring(1) : tagName;
      final releaseNotes = (data['body'] ?? '').toString();
      final publishedAt = DateTime.tryParse((data['published_at'] ?? '').toString()) ?? DateTime.now();

      final assets = data['assets'] as List<dynamic>? ?? [];

      // Determine asset match pattern based on OS and architecture
      final targetKeyword = _getAssetKeyword();
      if (targetKeyword == null) return null;

      Map<String, dynamic>? matchingAsset;
      for (final asset in assets) {
        if (asset is Map<String, dynamic>) {
          final name = (asset['name'] ?? '').toString().toLowerCase();
          if (name.contains(targetKeyword) &&
              (name.endsWith('.zip') || name.endsWith('.tar.gz'))) {
            matchingAsset = asset;
            break;
          }
        }
      }

      if (matchingAsset == null) return null;

      return RemoteReleaseInfo(
        tagName: tagName,
        version: version,
        releaseNotes: releaseNotes,
        assetName: (matchingAsset['name'] ?? '').toString(),
        downloadUrl: (matchingAsset['browser_download_url'] ?? '').toString(),
        assetSize: int.tryParse((matchingAsset['size'] ?? '0').toString()) ?? 0,
        publishedAt: publishedAt,
      );
    } catch (e) {
      AppLogger.error('[CoreUpdater] 解析内核 Release 数据失败: $e');
      return null;
    }
  }

  String? _getAssetKeyword() {
    if (Platform.isWindows) {
      return 'windows-amd64';
    } else if (Platform.isLinux) {
      return 'linux-amd64';
    } else if (Platform.isMacOS) {
      return 'darwin-universal';
    }
    return null;
  }

  /// Download archive and extract sing-box binary
  Future<String> downloadAndInstall({
    required String downloadUrl,
    required void Function(double progress, String status) onProgress,
    Future<void> Function()? onBeforeInstall,
  }) async {
    onProgress(0.05, 'Connecting to download server...');

    final downloadCandidates = [
      downloadUrl,
      'https://ghproxy.net/$downloadUrl',
      'https://mirror.ghproxy.com/$downloadUrl',
    ];

    List<int>? bytes;
    dynamic downloadErr;
    for (final candidate in downloadCandidates) {
      try {
        AppLogger.info('[CoreUpdater] 尝试下载内核包: $candidate');
        final response = await _dio.get<List<int>>(
          candidate,
          options: Options(responseType: ResponseType.bytes),
          onReceiveProgress: (received, total) {
            if (total > 0) {
              final progress = (received / total).clamp(0.05, 0.85);
              onProgress(progress, 'Downloading: ${(received / (1024 * 1024)).toStringAsFixed(1)} MB / ${(total / (1024 * 1024)).toStringAsFixed(1)} MB');
            }
          },
        );
        if (response.data != null && response.data!.isNotEmpty) {
          bytes = response.data;
          break;
        }
      } catch (e) {
        downloadErr = e;
        AppLogger.warn('[CoreUpdater] 下载源失败 ($candidate): $e');
      }
    }

    if (bytes == null || bytes.isEmpty) {
      throw Exception('Failed to download core archive: $downloadErr');
    }

    onProgress(0.88, 'Extracting core executable...');

    // Extract sing-box binary from downloaded archive
    List<int>? extractedBinaryBytes;
    final binaryName = Platform.isWindows ? 'sing-box.exe' : 'sing-box';

    if (downloadUrl.endsWith('.zip')) {
      final archive = ZipDecoder().decodeBytes(bytes);
      for (final file in archive) {
        if (file.isFile && (file.name.endsWith(binaryName) || file.name.endsWith('/$binaryName') || file.name == binaryName)) {
          extractedBinaryBytes = file.content as List<int>;
          break;
        }
      }
    } else if (downloadUrl.endsWith('.tar.gz') || downloadUrl.endsWith('.tgz')) {
      final tarBytes = GZipDecoder().decodeBytes(bytes);
      final archive = TarDecoder().decodeBytes(tarBytes);
      for (final file in archive) {
        if (file.isFile && (file.name.endsWith(binaryName) || file.name.endsWith('/$binaryName') || file.name == binaryName)) {
          extractedBinaryBytes = file.content as List<int>;
          break;
        }
      }
    }

    if (extractedBinaryBytes == null || extractedBinaryBytes.isEmpty) {
      throw Exception('Could not locate $binaryName inside the release archive.');
    }

    onProgress(0.92, 'Preparing to install binary...');

    // Determine target location (prefer application data/core directory or ./config)
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final primaryTargetDir = Directory(p.join(exeDir, 'data', 'core'));

    String targetFilePath;
    if (await primaryTargetDir.exists()) {
      targetFilePath = p.join(primaryTargetDir.path, binaryName);
    } else {
      try {
        await primaryTargetDir.create(recursive: true);
        targetFilePath = p.join(primaryTargetDir.path, binaryName);
      } catch (_) {
        final configDir = await StorageService.getAppConfigDir();
        targetFilePath = p.join(configDir.path, binaryName);
      }
    }

    // Write to a temporary file first so that the running core is unaffected during download and write
    final tempFilePath = '$targetFilePath.tmp_${DateTime.now().millisecondsSinceEpoch}';
    final tempFile = File(tempFilePath);
    await tempFile.writeAsBytes(extractedBinaryBytes);

    // Call onBeforeInstall hook (e.g. stop core right before replacing the file)
    onProgress(0.96, 'Applying new core binary...');
    if (onBeforeInstall != null) {
      await onBeforeInstall();
    }

    // Replace target binary
    final targetFile = File(targetFilePath);
    try {
      if (await targetFile.exists()) {
        try {
          await targetFile.delete();
        } catch (_) {
          // On Windows if still locked or in use, rename old file to .old
          final oldBackupPath = '$targetFilePath.old_${DateTime.now().millisecondsSinceEpoch}';
          try {
            await targetFile.rename(oldBackupPath);
          } catch (_) {}
        }
      }
      await tempFile.rename(targetFilePath);
    } catch (_) {
      // If rename fails, try direct byte copy
      await targetFile.writeAsBytes(extractedBinaryBytes);
      if (await tempFile.exists()) {
        try {
          await tempFile.delete();
        } catch (_) {}
      }
    }

    // Set executable permission on Unix
    if (!Platform.isWindows) {
      try {
        await Process.run('chmod', ['+x', targetFilePath]);
      } catch (_) {}
    }

    onProgress(1.0, 'Core updated successfully');
    return targetFilePath;
  }
}
