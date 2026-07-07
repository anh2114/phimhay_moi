package com.phimhay.phimhay_app

import android.content.Intent
import android.content.res.Configuration
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Rational
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val CHANNEL_INSTALL = "phimhay/install_apk"
    private val CHANNEL_AUDIO = "phimhay_app/audio"
    private val CHANNEL_PIP = "phimhay/pip"
    private var installChannel: MethodChannel? = null
    private var audioChannel: MethodChannel? = null
    private var pipChannel: MethodChannel? = null
    private var audioFocusRequest: AudioFocusRequest? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Install APK channel
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

        // Audio channel
        audioChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_AUDIO)
        audioChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "configureForPlayback" -> { requestAudioFocus(); result.success(true) }
                "setSpeaker" -> { result.success(true) }
                "configAVSession" -> { requestAudioFocus(); result.success(true) }
                "activateAudioSession" -> { result.success(true) }
                "checkMicPermission" -> { result.success(true) }
                else -> result.notImplemented()
            }
        }

        // PiP channel
        pipChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_PIP)
        pipChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "enterPiP" -> {
                    val width = call.argument<Int>("width") ?: 16
                    val height = call.argument<Int>("height") ?: 9
                    val params = android.app.PictureInPictureParams.Builder()
                        .setAspectRatio(Rational(width, height))
                        .build()
                    try {
                        enterPictureInPictureMode(params)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("PIP_ERROR", e.message, null)
                    }
                }
                "isPiP" -> result.success(isInPictureInPictureMode)
                "exitPiP" -> {
                    if (isInPictureInPictureMode) {
                        // PiP will be exited when user taps to expand
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onPictureInPictureModeChanged(inPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(inPictureInPictureMode, newConfig)
        pipChannel?.invokeMethod("onPiPModeChanged", inPictureInPictureMode)
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        // Auto-enter PiP when user presses home (optional - like YouTube)
        // Uncomment if you want auto-PiP on home press:
        // if (!isInPictureInPictureMode) {
        //     val params = android.app.PictureInPictureParams.Builder()
        //         .setAspectRatio(Rational(16, 9))
        //         .build()
        //     try { enterPictureInPictureMode(params) } catch (_: Exception) {}
        // }
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
}
