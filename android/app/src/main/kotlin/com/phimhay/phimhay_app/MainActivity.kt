package com.phimhay.phimhay_app

import android.app.PictureInPictureParams
import android.content.Intent
import android.content.res.Configuration
import android.graphics.BitmapFactory
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.Rational
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import fl.pip.FlPiPActivity

class MainActivity : FlPiPActivity() {
    private val CHANNEL_PIP = "phimhay/pip"
    private val CHANNEL_INSTALL = "phimhay/install_apk"
    private val CHANNEL_AUDIO = "phimhay_app/audio"
    private var pipChannel: MethodChannel? = null
    private var installChannel: MethodChannel? = null
    private var audioChannel: MethodChannel? = null
    private var pipPosition: Double = 0.0
    private var audioFocusRequest: AudioFocusRequest? = null
    private var autoPipEnabled: Boolean = false

    // ★ MediaSession — hiện controls play/pause/next/prev trong PiP
    private var mediaSession: MediaSession? = null
    private var isPlaying = false
    private var videoTitle = "Xiao Phim"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ★ Setup MediaSession cho PiP controls
        setupMediaSession()

        pipChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_PIP)
        pipChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "isPipAvailable" -> {
                    result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                }
                "setupPip" -> {
                    result.success(true)
                }
                "startPip" -> {
                    pipPosition = (call.argument<Number>("position") ?: 0).toDouble()
                    // Update MediaSession state
                    updateMediaSessionState(isPlaying, pipPosition)
                    try {
                        val params = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            PictureInPictureParams.Builder()
                                .setAspectRatio(Rational(16, 9))
                                .build()
                        } else {
                            null
                        }
                        if (params != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            if (!isInPictureInPictureMode) {
                                enterPictureInPictureMode(params)
                            }
                            result.success(true)
                        } else {
                            result.error("UNSUPPORTED", "PiP not supported", null)
                        }
                    } catch (e: Exception) {
                        result.error("ERROR", e.message, null)
                    }
                }
                "setAutoPip" -> {
                    autoPipEnabled = call.argument<Boolean>("enabled") ?: false
                    result.success(true)
                }
                "updatePipPosition" -> {
                    pipPosition = (call.argument<Number>("position") ?: 0).toDouble()
                    updateMediaSessionState(isPlaying, pipPosition)
                    result.success(true)
                }
                "updatePlaybackState" -> {
                    // Flutter báo playback state thay đổi (play/pause)
                    val playing = call.argument<Boolean>("isPlaying") ?: false
                    isPlaying = playing
                    val pos = call.argument<Number>("position")?.toDouble() ?: pipPosition
                    pipPosition = pos
                    updateMediaSessionState(isPlaying, pipPosition)
                    result.success(true)
                }
                "isPipActive" -> {
                    result.success(isInPictureInPictureMode)
                }
                "stopPip" -> {
                    result.success(true)
                }
                "getPipPosition" -> {
                    result.success(pipPosition)
                }
                else -> result.notImplemented()
            }
        }

        installChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_INSTALL)
        installChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "installApk" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrEmpty()) {
                        result.error("INVALID_PATH", "APK path is empty", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val file = File(path)
                        if (!file.exists()) {
                            result.error("FILE_NOT_FOUND", "APK file not found: $path", null)
                            return@setMethodCallHandler
                        }
                        installApk(file)
                        result.success("ok")
                    } catch (e: SecurityException) {
                        result.error("NEED_PERMISSION", e.message, null)
                    } catch (e: Exception) {
                        result.error("INSTALL_ERROR", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        audioChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_AUDIO)
        audioChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "configureForPlayback" -> {
                    requestAudioFocus()
                    result.success(true)
                }
                "setSpeaker" -> { result.success(true) }
                "configAVSession" -> {
                    requestAudioFocus()
                    result.success(true)
                }
                "activateAudioSession" -> { result.success(true) }
                "checkMicPermission" -> { result.success(true) }
                else -> result.notImplemented()
            }
        }
    }

    // ★ MediaSession — hiện play/pause/next/prev trong PiP overlay
    private fun setupMediaSession() {
        mediaSession = MediaSession(this, "XiaoPhim").apply {
            // Metadata — title hiển thị trong PiP
            val metadata = MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, videoTitle)
                .putString(MediaMetadata.METADATA_KEY_ARTIST, "Xiao Phim")
                .build()
            setMetadata(metadata)

            // Callback — xử lý nút bấm từ PiP controls
            setCallback(object : MediaSession.Callback() {
                override fun onPlay() {
                    // Gửi về Flutter: play
                    pipChannel?.invokeMethod("onMediaPlay", null)
                    isPlaying = true
                    updateMediaSessionState(true, pipPosition)
                }

                override fun onPause() {
                    // Gửi về Flutter: pause
                    pipChannel?.invokeMethod("onMediaPause", null)
                    isPlaying = false
                    updateMediaSessionState(false, pipPosition)
                }

                override fun onSkipToNext() {
                    // Gửi về Flutter: next episode
                    pipChannel?.invokeMethod("onMediaNext", null)
                }

                override fun onSkipToPrevious() {
                    // Gửi về Flutter: previous episode
                    pipChannel?.invokeMethod("onMediaPrevious", null)
                }

                override fun onSeekTo(pos: Long) {
                    // pos = milliseconds
                    pipPosition = pos / 1000.0
                    pipChannel?.invokeMethod("onMediaSeek", mapOf("position" to pipPosition))
                    updateMediaSessionState(isPlaying, pipPosition)
                }
            })

            isActive = true
        }
    }

    private fun updateMediaSessionState(playing: Boolean, positionSec: Double) {
        val state = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            PlaybackState.Builder()
                .setActions(
                    PlaybackState.ACTION_PLAY or
                    PlaybackState.ACTION_PAUSE or
                    PlaybackState.ACTION_PLAY_PAUSE or
                    PlaybackState.ACTION_SKIP_TO_NEXT or
                    PlaybackState.ACTION_SKIP_TO_PREVIOUS or
                    PlaybackState.ACTION_SEEK_TO
                )
                .setState(
                    if (playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
                    (positionSec * 1000).toLong(),
                    1.0f
                )
                .build()
        } else {
            @Suppress("DEPRECATION")
            PlaybackState.Builder()
                .setActions(
                    PlaybackState.ACTION_PLAY or
                    PlaybackState.ACTION_PAUSE or
                    PlaybackState.ACTION_PLAY_PAUSE or
                    PlaybackState.ACTION_SKIP_TO_NEXT or
                    PlaybackState.ACTION_SKIP_TO_PREVIOUS or
                    PlaybackState.ACTION_SEEK_TO
                )
                .setState(
                    if (playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
                    (positionSec * 1000).toLong(),
                    1.0f
                )
                .build()
        }
        mediaSession?.setPlaybackState(state)
    }

    private fun installApk(file: File) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            if (!packageManager.canRequestPackageInstalls()) {
                val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                    data = Uri.parse("package:$packageName")
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                startActivity(intent)
                throw SecurityException("NEED_PERMISSION")
            }
        }
        val uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            FileProvider.getUriForFile(this, "${packageName}.fileprovider", file)
        } else {
            Uri.fromFile(file)
        }
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(intent)
    }

    private fun requestAudioFocus() {
        val audioManager = getSystemService(AUDIO_SERVICE) as AudioManager
        val attrs = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val focusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(attrs)
                .setOnAudioFocusChangeListener { }
                .build()
            audioFocusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
            audioManager.requestAudioFocus(focusRequest)
            audioFocusRequest = focusRequest
        } else {
            @Suppress("DEPRECATION")
            audioManager.requestAudioFocus({ }, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN)
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (autoPipEnabled && !isInPictureInPictureMode && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                val params = PictureInPictureParams.Builder()
                    .setAspectRatio(Rational(16, 9))
                    .build()
                enterPictureInPictureMode(params)
            } catch (_: Exception) {}
        }
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration?) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        if (isInPictureInPictureMode) {
            pipChannel?.invokeMethod("onPipStarted", null)
        } else {
            pipChannel?.invokeMethod("onPipStopped", null)
        }
    }

    override fun onDestroy() {
        mediaSession?.release()
        mediaSession = null
        super.onDestroy()
    }
}
