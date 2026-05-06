// Copyright 2017 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
package uz.shs.better_player_plus

import android.app.Activity
import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.util.LongSparseArray
import android.util.Rational
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.media3.common.MediaItem
import uz.shs.better_player_plus.BetterPlayerCache.releaseCache
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.embedding.engine.plugins.FlutterPlugin.FlutterPluginBinding
import io.flutter.embedding.engine.loader.FlutterLoader
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.view.TextureRegistry
import java.lang.Exception
import java.util.HashMap

/**
 * Android platform implementation of the VideoPlayerPlugin.
 */
class BetterPlayerPlugin : FlutterPlugin, ActivityAware, MethodCallHandler {
    private val videoPlayers = LongSparseArray<BetterPlayer>()
    private val dataSources = LongSparseArray<Map<String, Any?>>()
    private var flutterState: FlutterState? = null
    private var currentNotificationTextureId: Long = -1
    private var currentNotificationDataSource: Map<String, Any?>? = null
    private var activity: Activity? = null
    private var pipHandler: Handler? = null
    private var pipRunnable: Runnable? = null
    private var pipReceiver: PipActionReceiver? = null
    private var pipPlayer: BetterPlayer? = null
    private var pipModeChangeListener: ((Boolean) -> Unit)? = null

    private var pipAutoEnter: Boolean = false
    override fun onAttachedToEngine(binding: FlutterPluginBinding) {
        val loader = FlutterLoader()
        flutterState = FlutterState(
            binding.applicationContext,
            binding.binaryMessenger, object : KeyForAssetFn {
                override fun get(asset: String?): String {
                    return loader.getLookupKeyForAsset(
                        asset!!
                    )
                }

            }, object : KeyForAssetAndPackageName {
                override fun get(asset: String?, packageName: String?): String {
                    return loader.getLookupKeyForAsset(
                        asset!!, packageName!!
                    )
                }
            },
            binding.textureRegistry
        )
        flutterState?.startListening(this)
    }


    override fun onDetachedFromEngine(binding: FlutterPluginBinding) {
        if (flutterState == null) {
            Log.wtf(TAG, "Detached from the engine before registering to it.")
        }
        disposeAllPlayers()
        releaseCache()
        flutterState?.stopListening()
        flutterState = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {}

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    private fun disposeAllPlayers() {
        for (i in 0 until videoPlayers.size()) {
            videoPlayers.valueAt(i).dispose()
        }
        videoPlayers.clear()
        dataSources.clear()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (flutterState == null || flutterState?.textureRegistry == null) {
            result.error("no_activity", "better_player plugin requires a foreground activity", null)
            return
        }
        when (call.method) {
            INIT_METHOD -> disposeAllPlayers()
            CREATE_METHOD -> {
                val handle = flutterState!!.textureRegistry!!.createSurfaceTexture()
                val eventChannel = EventChannel(
                    flutterState?.binaryMessenger, EVENTS_CHANNEL + handle.id()
                )
                var customDefaultLoadControl: CustomDefaultLoadControl? = null
                if (call.hasArgument(MIN_BUFFER_MS) && call.hasArgument(MAX_BUFFER_MS) &&
                    call.hasArgument(BUFFER_FOR_PLAYBACK_MS) &&
                    call.hasArgument(BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS)
                ) {
                    customDefaultLoadControl = CustomDefaultLoadControl(
                        call.argument(MIN_BUFFER_MS),
                        call.argument(MAX_BUFFER_MS),
                        call.argument(BUFFER_FOR_PLAYBACK_MS),
                        call.argument(BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS)
                    )
                }
                val player = BetterPlayer(
                    flutterState?.applicationContext!!, eventChannel, handle,
                    customDefaultLoadControl, result
                )
                videoPlayers.put(handle.id(), player)
            }

            PRE_CACHE_METHOD -> preCache(call, result)
            STOP_PRE_CACHE_METHOD -> stopPreCache(call, result)
            CLEAR_CACHE_METHOD -> clearCache(result)
            else -> {
                if (call.argument<Any>(TEXTURE_ID_PARAMETER) == null) {
//                    result.error(
//                        "Unknown textureId",
//                        "No video player associated with texture id",
//                        null
//                    )
                    return
                }
                val textureId = ((call.argument<Any>(TEXTURE_ID_PARAMETER) as Int?) ?: 0).toLong()
                val player = videoPlayers[textureId]
                if (player == null) {
                    result.error(
                        "Unknown textureId",
                        "No video player associated with texture id $textureId",
                        null
                    )
                    return
                }
                onMethodCall(call, result, textureId, player)
            }
        }
    }

    private fun onMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        textureId: Long,
        player: BetterPlayer
    ) {
        when (call.method) {
            SET_DATA_SOURCE_METHOD -> {
                setDataSource(call, result, player)
            }

            SET_PLAYLIST_METHOD -> {
                @Suppress("UNCHECKED_CAST")
                val rawItems = call.argument<List<Any?>>("items")
                    ?: call.argument<List<String>>("urls")
                    ?: emptyList<Any?>()
                val startIndex = call.argument<Int>("startIndex") ?: 0
                val items: List<Map<String, Any?>> = rawItems.mapNotNull { entry ->
                    when (entry) {
                        is Map<*, *> -> @Suppress("UNCHECKED_CAST") (entry as Map<String, Any?>)
                        is String -> mapOf("uri" to entry)
                        else -> null
                    }
                }
                if (items.isEmpty()) {
                    result.error(
                        "INVALID_ARGUMENT",
                        "setPlaylist requires at least one item",
                        null,
                    )
                    return
                }
                try {
                    player.setPlaylistItems(
                        flutterState!!.applicationContext,
                        items,
                        startIndex,
                    )
                    result.success(null)
                } catch (e: Throwable) {
                    Log.e(TAG, "setPlaylist failed", e)
                    result.error("PLAYLIST_FAILED", e.message, null)
                }
            }

            SET_AUTO_PIP_MODE_METHOD -> {
                val enabled = call.argument<Boolean>("enabled") ?: false
                setAutoPictureInPictureMode(player, enabled)
                result.success(null)
            }

            SET_LOOPING_METHOD -> {
                player.setLooping(call.argument(LOOPING_PARAMETER)!!)
                result.success(null)
            }

            SET_VOLUME_METHOD -> {
                player.setVolume(call.argument(VOLUME_PARAMETER)!!)
                result.success(null)
            }

            PLAY_METHOD -> {
                setupNotification(player)
                player.play()
                updateKeepScreenOnFlag()
                result.success(null)
            }

            PAUSE_METHOD -> {
                player.pause()
                result.success(null)
            }

            SEEK_TO_METHOD -> {
                val location = (call.argument<Any>(LOCATION_PARAMETER) as Number?)!!.toInt()
                player.seekTo(location)
                result.success(null)
            }

            POSITION_METHOD -> {
                result.success(player.position)
                player.sendBufferingUpdate(false)
            }

            ABSOLUTE_POSITION_METHOD -> result.success(player.absolutePosition)
            SET_SPEED_METHOD -> {
                player.setSpeed(call.argument(SPEED_PARAMETER)!!)
                result.success(null)
            }

            SET_TRACK_PARAMETERS_METHOD -> {
                player.setTrackParameters(
                    call.argument(WIDTH_PARAMETER)!!,
                    call.argument(HEIGHT_PARAMETER)!!,
                    call.argument(BITRATE_PARAMETER)!!
                )
                result.success(null)
            }

            ENABLE_PICTURE_IN_PICTURE_METHOD -> {
                enablePictureInPicture(player)
                result.success(null)
            }

            DISABLE_PICTURE_IN_PICTURE_METHOD -> {
                disablePictureInPicture(player)
                result.success(null)
            }

            IS_PICTURE_IN_PICTURE_SUPPORTED_METHOD -> result.success(
                isPictureInPictureSupported()
            )

            SET_AUDIO_TRACK_METHOD -> {
                val name = call.argument<String?>(NAME_PARAMETER)
                val index = call.argument<Int?>(INDEX_PARAMETER)
                if (name != null && index != null) {
                    player.setAudioTrack(name, index)
                }
                result.success(null)
            }

            SET_MIX_WITH_OTHERS_METHOD -> {
                val mixWitOthers = call.argument<Boolean?>(
                    MIX_WITH_OTHERS_PARAMETER
                )
                if (mixWitOthers != null) {
                    player.setMixWithOthers(mixWitOthers)
                }
            }

            DISPOSE_METHOD -> {
                dispose(player, textureId)
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    private fun setDataSource(
        call: MethodCall,
        result: MethodChannel.Result,
        player: BetterPlayer
    ) {
        val dataSource = call.argument<Map<String, Any?>>(DATA_SOURCE_PARAMETER)!!
        dataSources.put(getTextureId(player)!!, dataSource)
        val key = getParameter(dataSource, KEY_PARAMETER, "")
        val headers: Map<String, String> = getParameter(dataSource, HEADERS_PARAMETER, HashMap())
        val overriddenDuration: Number = getParameter(dataSource, OVERRIDDEN_DURATION_PARAMETER, 0)
        if (dataSource[ASSET_PARAMETER] != null) {
            val asset = getParameter(dataSource, ASSET_PARAMETER, "")
            val assetLookupKey: String = if (dataSource[PACKAGE_PARAMETER] != null) {
                val packageParameter = getParameter(
                    dataSource,
                    PACKAGE_PARAMETER,
                    ""
                )
                flutterState!!.keyForAssetAndPackageName[asset, packageParameter]
            } else {
                flutterState!!.keyForAsset[asset]
            }
            player.setDataSource(
                flutterState?.applicationContext!!,
                key,
                "asset:///$assetLookupKey",
                null,
                result,
                headers,
                false,
                0L,
                0L,
                overriddenDuration.toLong(),
                null,
                null, null, null
            )
        } else {
            val useCache = getParameter(dataSource, USE_CACHE_PARAMETER, false)
            val maxCacheSizeNumber: Number = getParameter(dataSource, MAX_CACHE_SIZE_PARAMETER, 0)
            val maxCacheFileSizeNumber: Number =
                getParameter(dataSource, MAX_CACHE_FILE_SIZE_PARAMETER, 0)
            val maxCacheSize = maxCacheSizeNumber.toLong()
            val maxCacheFileSize = maxCacheFileSizeNumber.toLong()
            val uri = getParameter(dataSource, URI_PARAMETER, "")
            val cacheKey = getParameter<String?>(dataSource, CACHE_KEY_PARAMETER, null)
            val formatHint = getParameter<String?>(dataSource, FORMAT_HINT_PARAMETER, null)
            val licenseUrl = getParameter<String?>(dataSource, LICENSE_URL_PARAMETER, null)
            val clearKey = getParameter<String?>(dataSource, DRM_CLEARKEY_PARAMETER, null)
            val drmHeaders: Map<String, String> =
                getParameter(dataSource, DRM_HEADERS_PARAMETER, HashMap())
            player.setDataSource(
                flutterState!!.applicationContext,
                key,
                uri,
                formatHint,
                result,
                headers,
                useCache,
                maxCacheSize,
                maxCacheFileSize,
                overriddenDuration.toLong(),
                licenseUrl,
                drmHeaders,
                cacheKey,
                clearKey
            )
        }
    }

    private fun preCache(call: MethodCall, result: MethodChannel.Result) {
        val dataSource = call.argument<Map<String, Any?>>(DATA_SOURCE_PARAMETER)
        if (dataSource != null) {
            val maxCacheSizeNumber: Number =
                getParameter(dataSource, MAX_CACHE_SIZE_PARAMETER, 100 * 1024 * 1024)
            val maxCacheFileSizeNumber: Number =
                getParameter(dataSource, MAX_CACHE_FILE_SIZE_PARAMETER, 10 * 1024 * 1024)
            val maxCacheSize = maxCacheSizeNumber.toLong()
            val maxCacheFileSize = maxCacheFileSizeNumber.toLong()
            val preCacheSizeNumber: Number =
                getParameter(dataSource, PRE_CACHE_SIZE_PARAMETER, 3 * 1024 * 1024)
            val preCacheSize = preCacheSizeNumber.toLong()
            val uri = getParameter(dataSource, URI_PARAMETER, "")
            val cacheKey = getParameter<String?>(dataSource, CACHE_KEY_PARAMETER, null)
            val headers: Map<String, String> =
                getParameter(dataSource, HEADERS_PARAMETER, HashMap())
            BetterPlayer.preCache(
                flutterState?.applicationContext,
                uri,
                preCacheSize,
                maxCacheSize,
                maxCacheFileSize,
                headers,
                cacheKey,
                result
            )
        }
    }

    private fun stopPreCache(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>(URL_PARAMETER)
        BetterPlayer.stopPreCache(flutterState?.applicationContext, url, result)
    }

    private fun clearCache(result: MethodChannel.Result) {
        BetterPlayer.clearCache(flutterState?.applicationContext, result)
    }

    private fun getTextureId(betterPlayer: BetterPlayer): Long? {
        for (index in 0 until videoPlayers.size()) {
            if (betterPlayer === videoPlayers.valueAt(index)) {
                return videoPlayers.keyAt(index)
            }
        }
        return null
    }

    private fun setupNotification(betterPlayer: BetterPlayer) {
        try {
            val textureId = getTextureId(betterPlayer)
            if (textureId != null) {
                val dataSource = dataSources[textureId]
                //Don't setup notification for the same source.
                if (textureId == currentNotificationTextureId && currentNotificationDataSource != null && dataSource != null && currentNotificationDataSource === dataSource) {
                    return
                }
                currentNotificationDataSource = dataSource
                currentNotificationTextureId = textureId
                removeOtherNotificationListeners()
                val showNotification = getParameter(dataSource, SHOW_NOTIFICATION_PARAMETER, false)
                if (showNotification) {
                    val title = getParameter(dataSource, TITLE_PARAMETER, "")
                    val author = getParameter(dataSource, AUTHOR_PARAMETER, "")
                    val imageUrl = getParameter(dataSource, IMAGE_URL_PARAMETER, "")
                    val notificationChannelName =
                        getParameter<String?>(dataSource, NOTIFICATION_CHANNEL_NAME_PARAMETER, null)
                    val activityName =
                        getParameter(dataSource, ACTIVITY_NAME_PARAMETER, "MainActivity")
                    betterPlayer.setupPlayerNotification(
                        flutterState?.applicationContext!!,
                        title, author, imageUrl, notificationChannelName, activityName
                    )
                }
            }
        } catch (exception: Exception) {
            Log.e(TAG, "SetupNotification failed", exception)
        }
    }

    private fun removeOtherNotificationListeners() {
        for (index in 0 until videoPlayers.size()) {
            videoPlayers.valueAt(index).disposeRemoteNotifications()
        }
    }

    @Suppress("UNCHECKED_CAST")
    private fun <T> getParameter(parameters: Map<String, Any?>?, key: String, defaultValue: T): T {
        if (parameters?.containsKey(key) == true) {
            val value = parameters[key]
            if (value != null) {
                return value as T
            }
        }
        return defaultValue
    }


    private fun isPictureInPictureSupported(): Boolean {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && activity != null && activity!!.packageManager
            .hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)
    }

    private fun enablePictureInPicture(player: BetterPlayer) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val act = activity ?: return
        player.setupMediaSession(flutterState!!.applicationContext)
        registerPipReceiver(player)

        try {
            act.enterPictureInPictureMode(buildPipParams(player))
        } catch (e: IllegalStateException) {
            Log.e(TAG, "enterPictureInPictureMode failed", e)
            unregisterPipReceiver()
            return
        }

        installPipModeListener(player)
        player.onPictureInPictureStatusChanged(true)
    }

    private fun disablePictureInPicture(player: BetterPlayer) {
        pipAutoEnter = false
        unregisterPipReceiver()
        removePipModeListener()
        stopPipHandler()
        player.onPictureInPictureStatusChanged(false)
        player.disposeMediaSession()
    }

    private fun registerPipReceiver(player: BetterPlayer) {
        unregisterPipReceiver()
        val appCtx = flutterState?.applicationContext ?: return
        val receiver = PipActionReceiver(player) { applyPipParams(player) }
        val filter = IntentFilter().apply {
            addAction(PipActionReceiver.ACTION_REWIND)
            addAction(PipActionReceiver.ACTION_FORWARD)
            addAction(PipActionReceiver.ACTION_TOGGLE)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            appCtx.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            appCtx.registerReceiver(receiver, filter)
        }
        pipReceiver = receiver
        pipPlayer = player
        player.pipPlayStateListener = { applyPipParams(player) }
        player.pipEndReachedListener = { dismissPipForEndOfVideo(player) }
    }

    private fun unregisterPipReceiver() {
        val rec = pipReceiver ?: return
        try {
            flutterState?.applicationContext?.unregisterReceiver(rec)
        } catch (_: IllegalArgumentException) {
            // already unregistered
        }
        pipPlayer?.pipPlayStateListener = null
        pipPlayer?.pipEndReachedListener = null
        pipReceiver = null
        pipPlayer = null
    }

    @android.annotation.TargetApi(Build.VERSION_CODES.O)
    private fun dismissPipForEndOfVideo(player: BetterPlayer) {
        val act = activity ?: return
        pipAutoEnter = false
        applyPipParams(player)
        if (act.isInPictureInPictureMode) {
            try {
                act.moveTaskToBack(true)
            } catch (e: Throwable) {
                Log.e(TAG, "moveTaskToBack on PiP end-of-video failed", e)
            }
        }
    }

    @android.annotation.TargetApi(Build.VERSION_CODES.O)
    private fun applyPipParams(player: BetterPlayer) {
        val act = activity ?: return
        try {
            act.setPictureInPictureParams(buildPipParams(player))
        } catch (_: IllegalStateException) {
            // Activity is leaving PiP / not in a state that accepts params.
        }
    }

    private fun setAutoPictureInPictureMode(player: BetterPlayer, enabled: Boolean) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        if (enabled) {
            pipAutoEnter = true
            // MediaSession + BroadcastReceiver setup is deferred to actual PiP entry
            // (too expensive at arm time; installPipModeListener does it lazily).
            applyPipParams(player)
            installPipModeListener(player)
        } else {
            pipAutoEnter = false
            applyPipParams(player)
            val act = activity
            // If PiP is currently active, let the mode listener finish the cycle.
            if (act != null && !act.isInPictureInPictureMode) {
                unregisterPipReceiver()
                removePipModeListener()
                player.disposeMediaSession()
            }
        }
    }

    @android.annotation.TargetApi(Build.VERSION_CODES.O)
    private fun buildPipParams(player: BetterPlayer): PictureInPictureParams {
        val ctx = flutterState!!.applicationContext
        // isActuallyPlaying (not isPlaying) so the icon matches frozen frames during STATE_BUFFERING.
        val playing = player.isActuallyPlaying
        val builder = PictureInPictureParams.Builder()

        val size = player.videoSize
        val ratio = if (size != null) clampedRational(size.first, size.second)
                    else Rational(9, 16)
        builder.setAspectRatio(ratio)

        val allActions = listOf(
            remoteAction(
                ctx,
                PipActionReceiver.ACTION_REWIND,
                PipActionReceiver.REQ_REWIND,
                android.R.drawable.ic_media_rew,
                "Rewind 10s",
            ),
            remoteAction(
                ctx,
                PipActionReceiver.ACTION_TOGGLE,
                PipActionReceiver.REQ_TOGGLE,
                if (playing) android.R.drawable.ic_media_pause
                else android.R.drawable.ic_media_play,
                if (playing) "Pause" else "Play",
            ),
            remoteAction(
                ctx,
                PipActionReceiver.ACTION_FORWARD,
                PipActionReceiver.REQ_FORWARD,
                android.R.drawable.ic_media_ff,
                "Forward 10s",
            ),
        )
        val maxActions = activity?.maxNumPictureInPictureActions ?: 3
        builder.setActions(allActions.take(maxActions.coerceAtLeast(0)))

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && pipAutoEnter) {
            builder.setAutoEnterEnabled(true)
            builder.setSeamlessResizeEnabled(true)
        }
        return builder.build()
    }

    // Falls back to 9:16 if ratio is outside the PiP-allowed range [1:2.39, 2.39:1].
    private fun clampedRational(w: Int, h: Int): Rational {
        if (w <= 0 || h <= 0) return Rational(9, 16)
        val ratio = Rational(w, h)
        val asDouble = ratio.toDouble()
        val min = 1.0 / 2.39
        val max = 2.39
        return if (asDouble in min..max) ratio else Rational(9, 16)
    }

    @android.annotation.TargetApi(Build.VERSION_CODES.O)
    private fun remoteAction(
        ctx: Context,
        action: String,
        requestCode: Int,
        iconRes: Int,
        title: String,
    ): RemoteAction {
        val intent = Intent(action).setPackage(ctx.packageName)
        val flags =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            else PendingIntent.FLAG_UPDATE_CURRENT
        val pi = PendingIntent.getBroadcast(ctx, requestCode, intent, flags)
        return RemoteAction(Icon.createWithResource(ctx, iconRes), title, title, pi)
    }

    @android.annotation.TargetApi(Build.VERSION_CODES.O)
    private fun installPipModeListener(player: BetterPlayer) {
        val act = activity ?: return
        if (pipHandler != null) return

        var lastInPip = act.isInPictureInPictureMode
        pipHandler = Handler(Looper.getMainLooper())
        pipRunnable = object : Runnable {
            override fun run() {
                val a = activity
                if (a == null) {
                    stopPipHandler()
                    return
                }
                val cur = a.isInPictureInPictureMode
                if (cur != lastInPip) {
                    lastInPip = cur
                    player.onPictureInPictureStatusChanged(cur)
                    if (cur) {
                        // Lazily install MediaSession + BroadcastReceiver deferred from arm time.
                        if (pipReceiver == null) {
                            try {
                                player.setupMediaSession(flutterState!!.applicationContext)
                                registerPipReceiver(player)
                                applyPipParams(player)
                            } catch (e: Throwable) {
                                Log.e(TAG, "Lazy PiP setup failed", e)
                            }
                        }
                    } else {
                        // PiP exited — pause if user tapped X (activity left screen), not Expand.
                        pauseIfActivityNotForegroundAfterPipExit(player)
                        unregisterPipReceiver()
                        player.disposeMediaSession()

                        if (pipAutoEnter) {
                            // Re-arm setAutoEnterEnabled for the next backgrounding.
                            applyPipParams(player)
                        } else {
                            removePipModeListener()
                            stopPipHandler()
                            return
                        }
                    }
                }
                if (cur || pipAutoEnter) {
                    pipHandler?.postDelayed(this, 250)
                } else {
                    stopPipHandler()
                }
            }
        }
        pipHandler?.postDelayed(pipRunnable!!, 250)
    }

    // Pauses only on PiP-Close (X), not on Expand. Uses lifecycle events to distinguish;
    // ON_RESUME/ON_START = Expand, ON_STOP = X. 800ms timeout as safety fallback.
    private fun pauseIfActivityNotForegroundAfterPipExit(player: BetterPlayer) {
        val a = activity ?: return
        val owner = a as? LifecycleOwner
        if (owner == null) {
            Handler(Looper.getMainLooper()).postDelayed({
                val act = activity ?: return@postDelayed
                if (!act.isInPictureInPictureMode &&
                    act.window?.decorView?.isShown != true) {
                    try { player.pause() } catch (_: Throwable) {}
                }
            }, 600)
            return
        }

        val mainHandler = Handler(Looper.getMainLooper())
        val timeoutMarker = Any()
        var settled = false
        lateinit var observer: androidx.lifecycle.LifecycleEventObserver
        observer = androidx.lifecycle.LifecycleEventObserver { _, event ->
            if (settled) return@LifecycleEventObserver
            when (event) {
                androidx.lifecycle.Lifecycle.Event.ON_RESUME,
                androidx.lifecycle.Lifecycle.Event.ON_START -> {
                    settled = true
                    owner.lifecycle.removeObserver(observer)
                    mainHandler.removeCallbacksAndMessages(timeoutMarker)
                }
                androidx.lifecycle.Lifecycle.Event.ON_STOP,
                androidx.lifecycle.Lifecycle.Event.ON_DESTROY -> {
                    settled = true
                    owner.lifecycle.removeObserver(observer)
                    mainHandler.removeCallbacksAndMessages(timeoutMarker)
                    try {
                        player.pause()
                    } catch (e: Throwable) {
                        Log.e(TAG, "Failed to pause player after PiP X-tap", e)
                    }
                }
                else -> {}
            }
        }
        owner.lifecycle.addObserver(observer)

        val timeoutRunnable = Runnable {
            if (settled) return@Runnable
            settled = true
            owner.lifecycle.removeObserver(observer)
            val isVisible = owner.lifecycle.currentState
                .isAtLeast(androidx.lifecycle.Lifecycle.State.STARTED)
            if (!isVisible) {
                try { player.pause() } catch (_: Throwable) {}
            }
        }
        mainHandler.postAtTime(
            timeoutRunnable,
            timeoutMarker,
            android.os.SystemClock.uptimeMillis() + 800,
        )
    }

    private fun removePipModeListener() {
        pipModeChangeListener = null
        stopPipHandler()
    }

    private fun dispose(player: BetterPlayer, textureId: Long) {
        if (pipPlayer === player) {
            pipAutoEnter = false
            unregisterPipReceiver()
            removePipModeListener()
            try {
                player.disposeMediaSession()
            } catch (e: Throwable) {
                Log.e(TAG, "disposeMediaSession on plugin dispose failed", e)
            }
        }
        try {
            player.dispose()
        } catch (e: Throwable) {
            Log.e(TAG, "player.dispose() failed", e)
        }
        videoPlayers.remove(textureId)
        dataSources.remove(textureId)
        updateKeepScreenOnFlag()
        stopPipHandler()
    }

    private fun updateKeepScreenOnFlag() {
        val hasKeepScreenOnPlayer = (0 until dataSources.size()).any { i ->
            val ds = dataSources[dataSources.keyAt(i)]
            !getParameter(ds, ALLOWED_SCREEN_SLEEP_PARAMETER, true)
        }
        if (hasKeepScreenOnPlayer) {
            activity?.window?.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        } else {
            activity?.window?.clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }

    private fun stopPipHandler() {
        if (pipHandler != null) {
            pipHandler!!.removeCallbacksAndMessages(null)
            pipHandler = null
        }
        pipRunnable = null
    }

    private interface KeyForAssetFn {
        operator fun get(asset: String?): String
    }

    private interface KeyForAssetAndPackageName {
        operator fun get(asset: String?, packageName: String?): String
    }

    private class FlutterState(
        val applicationContext: Context,
        val binaryMessenger: BinaryMessenger,
        val keyForAsset: KeyForAssetFn,
        val keyForAssetAndPackageName: KeyForAssetAndPackageName,
        val textureRegistry: TextureRegistry?
    ) {
        private val methodChannel: MethodChannel = MethodChannel(binaryMessenger, CHANNEL)

        fun startListening(methodCallHandler: BetterPlayerPlugin?) {
            methodChannel.setMethodCallHandler(methodCallHandler)
        }

        fun stopListening() {
            methodChannel.setMethodCallHandler(null)
        }

    }

    companion object {
        private const val TAG = "BetterPlayerPlugin"
        private const val CHANNEL = "better_player_channel"
        private const val EVENTS_CHANNEL = "better_player_channel/videoEvents"
        private const val DATA_SOURCE_PARAMETER = "dataSource"
        private const val KEY_PARAMETER = "key"
        private const val HEADERS_PARAMETER = "headers"
        private const val USE_CACHE_PARAMETER = "useCache"
        private const val ASSET_PARAMETER = "asset"
        private const val PACKAGE_PARAMETER = "package"
        private const val URI_PARAMETER = "uri"
        private const val FORMAT_HINT_PARAMETER = "formatHint"
        private const val TEXTURE_ID_PARAMETER = "textureId"
        private const val LOOPING_PARAMETER = "looping"
        private const val VOLUME_PARAMETER = "volume"
        private const val LOCATION_PARAMETER = "location"
        private const val SPEED_PARAMETER = "speed"
        private const val WIDTH_PARAMETER = "width"
        private const val HEIGHT_PARAMETER = "height"
        private const val BITRATE_PARAMETER = "bitrate"
        private const val SHOW_NOTIFICATION_PARAMETER = "showNotification"
        private const val TITLE_PARAMETER = "title"
        private const val AUTHOR_PARAMETER = "author"
        private const val IMAGE_URL_PARAMETER = "imageUrl"
        private const val NOTIFICATION_CHANNEL_NAME_PARAMETER = "notificationChannelName"
        private const val OVERRIDDEN_DURATION_PARAMETER = "overriddenDuration"
        private const val NAME_PARAMETER = "name"
        private const val INDEX_PARAMETER = "index"
        private const val LICENSE_URL_PARAMETER = "licenseUrl"
        private const val DRM_HEADERS_PARAMETER = "drmHeaders"
        private const val DRM_CLEARKEY_PARAMETER = "clearKey"
        private const val MIX_WITH_OTHERS_PARAMETER = "mixWithOthers"
        private const val ALLOWED_SCREEN_SLEEP_PARAMETER = "allowedScreenSleep"
        const val URL_PARAMETER = "url"
        const val PRE_CACHE_SIZE_PARAMETER = "preCacheSize"
        const val MAX_CACHE_SIZE_PARAMETER = "maxCacheSize"
        const val MAX_CACHE_FILE_SIZE_PARAMETER = "maxCacheFileSize"
        const val HEADER_PARAMETER = "header_"
        const val FILE_PATH_PARAMETER = "filePath"
        const val ACTIVITY_NAME_PARAMETER = "activityName"
        const val MIN_BUFFER_MS = "minBufferMs"
        const val MAX_BUFFER_MS = "maxBufferMs"
        const val BUFFER_FOR_PLAYBACK_MS = "bufferForPlaybackMs"
        const val BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS = "bufferForPlaybackAfterRebufferMs"
        const val CACHE_KEY_PARAMETER = "cacheKey"
        private const val INIT_METHOD = "init"
        private const val CREATE_METHOD = "create"
        private const val SET_DATA_SOURCE_METHOD = "setDataSource"
        private const val SET_PLAYLIST_METHOD = "setPlaylist"
        private const val SET_AUTO_PIP_MODE_METHOD = "setAutoPictureInPictureMode"
        private const val SET_LOOPING_METHOD = "setLooping"
        private const val SET_VOLUME_METHOD = "setVolume"
        private const val PLAY_METHOD = "play"
        private const val PAUSE_METHOD = "pause"
        private const val SEEK_TO_METHOD = "seekTo"
        private const val POSITION_METHOD = "position"
        private const val ABSOLUTE_POSITION_METHOD = "absolutePosition"
        private const val SET_SPEED_METHOD = "setSpeed"
        private const val SET_TRACK_PARAMETERS_METHOD = "setTrackParameters"
        private const val SET_AUDIO_TRACK_METHOD = "setAudioTrack"
        private const val ENABLE_PICTURE_IN_PICTURE_METHOD = "enablePictureInPicture"
        private const val DISABLE_PICTURE_IN_PICTURE_METHOD = "disablePictureInPicture"
        private const val IS_PICTURE_IN_PICTURE_SUPPORTED_METHOD = "isPictureInPictureSupported"
        private const val SET_MIX_WITH_OTHERS_METHOD = "setMixWithOthers"
        private const val CLEAR_CACHE_METHOD = "clearCache"
        private const val DISPOSE_METHOD = "dispose"
        private const val PRE_CACHE_METHOD = "preCache"
        private const val STOP_PRE_CACHE_METHOD = "stopPreCache"
    }
}