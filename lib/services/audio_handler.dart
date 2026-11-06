import 'dart:io' show File, Platform;
import 'dart:ui' show PlatformDispatcher;

import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/grpc/bilibili/app/listener/v1.pb.dart' show DetailItem;
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/models_new/live/live_room_info_h5/data.dart';
import 'package:PiliPlus/models_new/pgc/pgc_info_model/episode.dart';
import 'package:PiliPlus/models_new/video/video_detail/data.dart';
import 'package:PiliPlus/models_new/video/video_detail/page.dart';
import 'package:PiliPlus/pages/common/common_intro_controller.dart';
import 'package:PiliPlus/pages/video/introduction/local/controller.dart';
import 'package:PiliPlus/pages/video/introduction/pgc/controller.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/controller.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/utils/android/bindings.g.dart';
import 'package:PiliPlus/utils/device_utils.dart';
import 'package:PiliPlus/utils/image_utils.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:audio_service/audio_service.dart';
import 'package:audio_service_mpris/audio_service_mpris.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:get/get_core/src/get_main.dart';
import 'package:get/get_instance/src/extension_instance.dart';
import 'package:jni/jni.dart' show JStringExtension;
import 'package:path/path.dart' as path;

Future<VideoPlayerServiceHandler> initAudioService() {
  if (Platform.isLinux) {
    AudioServiceMpris.init(
      dBusName: 'com.example.piliplus.audio',
      identity: Constants.appName,
      desktopEntry: 'com.example.piliplus',
      canGoNext: true,
      canGoPrevious: true,
      canPlay: true,
      canPause: true,
      canControl: true,
    );
  }
  return AudioService.init(
    builder: VideoPlayerServiceHandler.new,
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.example.piliplus.audio',
      androidNotificationChannelName: 'Audio Service ${Constants.appName}',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
      fastForwardInterval: Duration(seconds: 10),
      rewindInterval: Duration(seconds: 10),
      androidNotificationChannelDescription: 'Media notification channel',
      androidNotificationIcon: 'drawable/ic_notification_icon',
    ),
  );
}

typedef _StatusConfig = (
  PlayerStatus status,
  bool isBuffering,
  bool isLive,
  double speed,
);

class VideoPlayerServiceHandler extends BaseAudioHandler with SeekHandler {
  VideoPlayerServiceHandler() {
    // Android 14 dispatches volume keys from the activity straight to the
    // session without checking canHandleVolumeKey(), so a FIXED remote
    // session swallows them there. Only verified to fall back on Android 16.
    if (Platform.isAndroid && DeviceUtils.sdkInt >= 36) {
      final jStr = AndroidHelper.manufacturer();
      if (jStr != null &&
          jStr.toDartString(releaseOriginal: true).toLowerCase() == 'vivo') {
        androidPlaybackInfo.add(
          RemoteAndroidPlaybackInfo(
            volumeControlType: .fixed,
            maxVolume: 100,
            volume: 50,
          ),
        );
      }
    }
  }

  static final List<MediaItem> _item = [];
  bool enableBackgroundPlay = Pref.enableBackgroundPlay;

  Future<void>? Function()? onPlay;
  Future<void>? Function()? onPause;
  Future<void>? Function(Duration position)? onSeek;
  void Function()? onSkipToNext;
  void Function()? onSkipToPrevious;

  @override
  Future<void> play() {
    return onPlay?.call() ??
        PlPlayerController.playIfExists() ??
        Future.syncValue(null);
  }

  @override
  Future<void> pause() {
    return onPause?.call() ??
        PlPlayerController.pauseIfExists() ??
        Future.syncValue(null);
  }

  CommonIntroController? _findIntroController() {
    final playOwner = PlPlayerController.playOwner;
    if (playOwner != null) {
      final tag = playOwner.tag;
      try {
        return switch (playOwner.type) {
          UgcIntroController _ => Get.find<UgcIntroController>(tag: tag),
          PgcIntroController _ => Get.find<PgcIntroController>(tag: tag),
          LocalIntroController _ => Get.find<LocalIntroController>(tag: tag),
          _ => throw UnimplementedError(playOwner.type.toString()),
        };
      } catch (_) {
        if (kDebugMode) rethrow;
      }
    }
    return null;
  }

  @override
  Future<void> skipToNext() {
    final func = onSkipToNext ?? _findIntroController()?.nextPlay;
    return func == null ? Future.syncValue(null) : Future.sync(func);
  }

  @override
  Future<void> skipToPrevious() {
    final func = onSkipToPrevious ?? _findIntroController()?.prevPlay;
    return func == null ? Future.syncValue(null) : Future.sync(func);
  }

  @override
  Future<void> seek(Duration position) {
    return onSeek?.call(position) ??
        PlPlayerController.seekToIfExists(position, isSeek: false) ??
        Future.syncValue(null);
  }

  // ──────────────────────────────────────────────────────────────
  // 改动 1：新增 PiP 连续 seek 的待处理目标位置与步长
  // 根因：SeekHandler 默认的 rewind()/fastForward() 以
  // playbackState.value.position 为基准，而 seek 后缓冲期间该值
  // 不会更新，导致连续点击的目标位置不变、无法累加。
  // 这里用一个本地 _pendingSeek 记录连续 seek 的目标位置作为累加基准。
  // ──────────────────────────────────────────────────────────────
  Duration? _pendingSeek;
  static const _pipSeekStep = Duration(seconds: 10);

  Duration get _seekBase => _pendingSeek ?? playbackState.value.position;

  // 改动 2：重写 rewind()/fastForward()，支持连续点击累加
  @override
  Future<void> rewind() {
    final target = _seekBase - _pipSeekStep;
    _pendingSeek = target.isNegative ? Duration.zero : target;
    return seek(_pendingSeek!);
  }

  @override
  Future<void> fastForward() {
    var target = _seekBase + _pipSeekStep;
    final duration = mediaItem.value?.duration;
    if (duration != null && target > duration) {
      target = duration;
    }
    _pendingSeek = target;
    return seek(target);
  }

  void setMediaItem(MediaItem newMediaItem) {
    if (!enableBackgroundPlay) return;
    // if (kDebugMode) {
    //   debugPrint("此时调用栈为：");
    //   debugPrint(newMediaItem);
    //   debugPrint(newMediaItem.title);
    //   debugPrint(StackTrace.current.toString());
    // }
    if (!mediaItem.isClosed) mediaItem.add(newMediaItem);
  }

  Duration? _lastPos;
  _StatusConfig? _lastConfig;
  void onUpdateState(
    PlayerStatus status,
    bool isBuffering,
    bool isLive, {
    required Duration position,
    required double speed,
    String? debugLabel,
  }) {
    // ──────────────────────────────────────────────────────────
    // 改动 3：真实播放位置追近待处理目标（2 秒容差）后清空
    // _pendingSeek，避免后续正常播放时从旧目标漂移。
    // 放在所有 return 之前，确保去重逻辑不会跳过清理。
    // ──────────────────────────────────────────────────────────
    if (_pendingSeek != null &&
        (position - _pendingSeek!).abs() <= const Duration(seconds: 2)) {
      _pendingSeek = null;
    }

    if (!enableBackgroundPlay || _item.isEmpty) {
      return;
    }

    if (onPlay != null && debugLabel == 'onVideoPaused') return;

    final newConfig = (status, isBuffering, isLive, speed);
    if (_lastConfig == newConfig) {
      if (_lastPos != null) {
        final pos = position.inSeconds;
        final lastPos = _lastPos!.inSeconds;
        _lastPos = position;
        if (pos == lastPos && pos != 0) return;
      }
    }
    _lastConfig = newConfig;

    final AudioProcessingState processingState;
    final bool playing;
    switch (status) {
      case .completed:
        playing = false;
        processingState = .completed;
      case .playing:
        playing = true;
        processingState = isBuffering ? .buffering : .ready;
      case .paused:
        playing = isBuffering;
        processingState = isBuffering ? .buffering : .ready;
    }
    _updateState(
      processingState,
      playing,
      isLive,
      position: position,
      speed: speed,
    );
  }

  void _updateState(
    AudioProcessingState state,
    bool playing,
    bool isLive, {
    required Duration position,
    required double speed,
  }) {
    playbackState.add(
      playbackState.value.copyWith(
        processingState: state,
        updatePosition: position,
        speed: speed,
        controls: [
          if (!isLive)
            const MediaControl(
              androidIcon: 'drawable/ic_player_rewind_10s',
              label: 'Rewind',
              action: .rewind,
            ),
          if (playing)
            const MediaControl(
              androidIcon: 'drawable/ic_player_pause',
              label: 'Pause',
              action: .pause,
            )
          else
            const MediaControl(
              androidIcon: 'drawable/ic_player_play',
              label: 'Play',
              action: .play,
            ),
          if (!isLive)
            const MediaControl(
              androidIcon: 'drawable/ic_player_fast_forward_10s',
              label: 'Fast Forward',
              action: .fastForward,
            ),
        ],
        playing: playing,
        systemActions: const {.seek},
      ),
    );
    if (Platform.isAndroid &&
        (AndroidHelper.isPipMode ||
            PlPlayerController.instance?.isAutoEnterPip == true)) {
      AndroidHelper.updatePipActions(
        PlatformDispatcher.instance.engineId!,
        isLive,
        playing,
      );
    }
  }

  void onVideoDetailChange(
    dynamic data,
    int cid,
    String herotag, {
    String? artist,
    String? cover,
  }) {
    if (!enableBackgroundPlay) return;
    // if (kDebugMode) {
    //   debugPrint('当前调用栈为：');
    //   debugPrint(StackTrace.current);
    // }
    if (data == null) return;

    Uri getUri(String? cover) => Uri.parse(ImageUtils.safeThumbnailUrl(cover));

    late final id = '$cid$herotag';
    final MediaItem mediaItem;
    switch (data) {
      case VideoDetailData(:final pages):
        if (pages != null && pages.length > 1) {
          final current = pages.firstWhereOrNull((e) => e.cid == cid);
          mediaItem = MediaItem(
            id: id,
            title: current?.part ?? '',
            artist: data.owner?.name,
            duration: Duration(seconds: current?.duration ?? 0),
            artUri: getUri(data.pic),
          );
        } else {
          mediaItem = MediaItem(
            id: id,
            title: data.title ?? '',
            artist: data.owner?.name,
            duration: Duration(seconds: data.duration ?? 0),
            artUri: getUri(data.pic),
          );
        }
      case EpisodeItem():
        mediaItem = MediaItem(
          id: id,
          title: data.showTitle ?? data.longTitle ?? data.title ?? '',
          artist: artist,
          duration: data.from == 'pugv'
              ? Duration(seconds: data.duration ?? 0)
              : Duration(milliseconds: data.duration ?? 0),
          artUri: getUri(data.cover),
        );
      case RoomInfoH5Data():
        mediaItem = MediaItem(
          id: id,
          title: data.roomInfo?.title ?? '',
          artist: data.anchorInfo?.baseInfo?.uname,
          artUri: getUri(data.roomInfo?.cover),
          isLive: true,
        );
      case Part():
        mediaItem = MediaItem(
          id: id,
          title: data.part ?? '',
          artist: artist,
          duration: Duration(seconds: data.duration ?? 0),
          artUri: getUri(cover),
        );
      case DetailItem(:final arc):
        mediaItem = MediaItem(
          id: id,
          title: arc.title,
          artist: data.owner.name,
          duration: Duration(seconds: arc.duration.toInt()),
          artUri: getUri(arc.cover),
        );
      case BiliDownloadEntryInfo():
        final coverFile = File(
          path.join(data.entryDirPath, PathUtils.coverName),
        );
        final uri = coverFile.existsSync()
            ? coverFile.absolute.uri
            : getUri(data.cover);
        mediaItem = MediaItem(
          id: id,
          title: data.showTitle,
          artist: data.ownerName,
          duration: Duration(milliseconds: data.totalTimeMilli),
          artUri: uri,
        );
      default:
        return;
    }
    _item.add(mediaItem);
    setMediaItem(mediaItem);
  }

  void onVideoDetailDispose(String herotag) {
    if (!enableBackgroundPlay) return;

    if (_item.isNotEmpty) {
      _item.removeWhere((item) => item.id.endsWith(herotag));
    }
    if (_item.isNotEmpty) {
      setMediaItem(_item.last);
      playbackState.add(
        playbackState.value.copyWith(processingState: .ready, playing: false),
      );
    }
  }

  void clearIfNeeded() {
    if (!enableBackgroundPlay) return;
    if (_item.isEmpty) clear();
  }

  void clear() {
    if (!enableBackgroundPlay) return;
    mediaItem.add(null);
    _item.clear();
    _lastPos = null;
    _lastConfig = null;
    // 改动 4：清理时同时清空 pending seek，避免串到下一个媒体
    _pendingSeek = null;
    /**
     * if (playbackState.processingState == AudioProcessingState.idle &&
            previousState?.processingState != AudioProcessingState.idle) {
          await AudioService._stop();
        }
     */
    if (playbackState.value.processingState == .idle) {
      playbackState.add(PlaybackState(processingState: .completed));
    }
    playbackState.add(PlaybackState(processingState: .idle));
  }
}