package com.cloudflare.cloudflared_tunnel

import android.Manifest
import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry
import mobile.Mobile

/**
 * CloudflaredTunnelPlugin - Flutter plugin that manages cloudflared tunnel via foreground service.
 *
 * The tunnel runs in a foreground service that survives:
 * - App being closed/swiped from recent apps
 * - Notification being dismissed (notification reappears)
 * - App process being killed (service restarts with START_STICKY)
 *
 * Similar to Termux's approach for persistent background execution.
 */
class CloudflaredTunnelPlugin : FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler,
    ActivityAware, PluginRegistry.RequestPermissionsResultListener {

    companion object {
        private const val NOTIFICATION_PERMISSION_REQUEST_CODE = 19876
    }

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    private var applicationContext: Context? = null
    private var activity: Activity? = null
    private var cloudflaredService: CloudflaredService? = null
    private var serviceBound = false
    private var pendingPermissionResult: Result? = null

    private val serviceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            val localBinder = binder as? CloudflaredService.LocalBinder
            cloudflaredService = localBinder?.getService()
            serviceBound = true

            // Set up callbacks from service to Flutter
            cloudflaredService?.tunnelEventCallback = { type, data ->
                sendEvent(type, data)
            }
            cloudflaredService?.serverEventCallback = { type, data ->
                sendEvent(type, data)
            }

            // Sync current state to Flutter
            syncServiceState()
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            cloudflaredService = null
            serviceBound = false
        }
    }

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = flutterPluginBinding.applicationContext

        methodChannel = MethodChannel(
            flutterPluginBinding.binaryMessenger,
            "com.cloudflare.cloudflared_tunnel/methods"
        )
        methodChannel.setMethodCallHandler(this)

        eventChannel = EventChannel(
            flutterPluginBinding.binaryMessenger,
            "com.cloudflare.cloudflared_tunnel/events"
        )
        eventChannel.setStreamHandler(this)

        // Bind to existing service if running
        bindToServiceIfRunning()
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            // Tunnel methods
            "start" -> handleStart(call, result)
            "stop" -> handleStop(result)
            "getState" -> handleGetState(result)
            "getVersion" -> handleGetVersion(result)
            "validateToken" -> handleValidateToken(call, result)
            "isRunning" -> handleIsRunning(result)

            // Server methods
            "startServer" -> handleStartServer(call, result)
            "stopServer" -> handleStopServer(result)
            "getServerState" -> handleGetServerState(result)
            "getServerUrl" -> handleGetServerUrl(result)
            "isServerRunning" -> handleIsServerRunning(result)
            "getRequestLogs" -> handleGetRequestLogs(result)
            "clearRequestLogs" -> handleClearRequestLogs(result)
            "listDirectory" -> handleListDirectory(call, result)

            // Service methods
            "isServiceRunning" -> handleIsServiceRunning(result)
            "stopService" -> handleStopService(result)

            // Permission methods
            "requestNotificationPermission" -> handleRequestNotificationPermission(result)
            "hasNotificationPermission" -> handleHasNotificationPermission(result)

            else -> result.notImplemented()
        }
    }

    // ========================================================================
    // Service Management
    // ========================================================================

    private fun startServiceIfNeeded(): Boolean {
        val context = applicationContext ?: return false

        if (!CloudflaredService.isServiceRunning()) {
            val serviceIntent = Intent(context, CloudflaredService::class.java)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(serviceIntent)
            } else {
                context.startService(serviceIntent)
            }
        }

        // Bind to service
        if (!serviceBound) {
            val serviceIntent = Intent(context, CloudflaredService::class.java)
            context.bindService(serviceIntent, serviceConnection, Context.BIND_AUTO_CREATE)
        }

        return true
    }

    private fun bindToServiceIfRunning() {
        val context = applicationContext ?: return

        if (CloudflaredService.isServiceRunning() && !serviceBound) {
            val serviceIntent = Intent(context, CloudflaredService::class.java)
            context.bindService(serviceIntent, serviceConnection, Context.BIND_AUTO_CREATE)
        }
    }

    private fun syncServiceState() {
        // Send current state to Flutter when reconnecting
        if (CloudflaredService.isTunnelRunning) {
            sendEvent("stateChanged", mapOf(
                "state" to 2, // Connected
                "message" to "Tunnel connected (resumed)"
            ))
        } else if (CloudflaredService.currentTunnelState > 0) {
            sendEvent("stateChanged", mapOf(
                "state" to CloudflaredService.currentTunnelState,
                "message" to "Tunnel state synced"
            ))
        }

        if (CloudflaredService.isServerRunning) {
            sendEvent("serverStateChanged", mapOf(
                "state" to 2, // Running
                "message" to "Server running (resumed)"
            ))
        }
    }

    // ========================================================================
    // Tunnel Methods
    // ========================================================================

    private fun handleStart(call: MethodCall, result: Result) {
        val token = call.argument<String>("token")
        val originUrl = call.argument<String>("originUrl") ?: ""

        if (token.isNullOrEmpty()) {
            result.error("INVALID_TOKEN", "Token is required", null)
            return
        }

        if (CloudflaredService.isTunnelRunning) {
            result.error("ALREADY_RUNNING", "Tunnel is already running", null)
            return
        }

        // Start service and tunnel
        if (!startServiceIfNeeded()) {
            result.error("SERVICE_ERROR", "Failed to start service", null)
            return
        }

        // Wait for service to bind, then start tunnel
        mainHandler.postDelayed({
            cloudflaredService?.startTunnel(token, originUrl) { success, error ->
                if (!success && error != null) {
                    // Error already sent via callback
                }
            } ?: run {
                sendEvent("error", mapOf("code" to 1, "message" to "Service not ready"))
            }
        }, 100)

        result.success(null)
    }

    private fun handleStop(result: Result) {
        cloudflaredService?.stopTunnel() ?: run {
            try {
                Mobile.stopTunnel()
            } catch (e: Exception) {
                // Ignore
            }
        }

        // Also reset Prometheus metrics to allow clean restart
        try {
            Mobile.forceReset()
        } catch (e: Exception) {
            // Ignore
        }

        result.success(null)
    }

    private fun handleGetState(result: Result) {
        val state = CloudflaredService.currentTunnelState
        result.success(state)
    }

    private fun handleGetVersion(result: Result) {
        try {
            val version = Mobile.getVersion()
            result.success(version)
        } catch (e: Exception) {
            result.success("unknown")
        }
    }

    private fun handleValidateToken(call: MethodCall, result: Result) {
        val token = call.argument<String>("token")

        if (token.isNullOrEmpty()) {
            result.error("INVALID_TOKEN", "Token is required", null)
            return
        }

        try {
            val tunnelId = Mobile.validateToken(token)
            result.success(tunnelId)
        } catch (e: Exception) {
            result.error("INVALID_TOKEN", e.message, null)
        }
    }

    private fun handleIsRunning(result: Result) {
        result.success(CloudflaredService.isTunnelRunning)
    }

    // ========================================================================
    // Server Methods
    // ========================================================================

    private fun handleStartServer(call: MethodCall, result: Result) {
        val rootDir = call.argument<String>("rootDir")
        val port = call.argument<Int>("port") ?: 8080

        if (rootDir.isNullOrEmpty()) {
            result.error("INVALID_DIR", "Root directory is required", null)
            return
        }

        if (CloudflaredService.isServerRunning) {
            result.error("ALREADY_RUNNING", "Server is already running", null)
            return
        }

        // Start service and server
        if (!startServiceIfNeeded()) {
            result.error("SERVICE_ERROR", "Failed to start service", null)
            return
        }

        mainHandler.postDelayed({
            cloudflaredService?.startServer(rootDir, port) { success, error ->
                if (!success && error != null) {
                    // Error sent via callback
                }
            } ?: run {
                sendEvent("serverError", mapOf("code" to 1, "message" to "Service not ready"))
            }
        }, 100)

        result.success(null)
    }

    private fun handleStopServer(result: Result) {
        cloudflaredService?.stopServer() ?: run {
            try {
                Mobile.stopLocalServer()
            } catch (e: Exception) {
                // Ignore
            }
        }
        result.success(null)
    }

    private fun handleGetServerState(result: Result) {
        val state = CloudflaredService.currentServerState
        result.success(state)
    }

    private fun handleGetServerUrl(result: Result) {
        try {
            val url = Mobile.getLocalServerURL()
            result.success(url)
        } catch (e: Exception) {
            result.success("")
        }
    }

    private fun handleIsServerRunning(result: Result) {
        result.success(CloudflaredService.isServerRunning)
    }

    private fun handleGetRequestLogs(result: Result) {
        try {
            val logs = Mobile.getLocalServerRequestLogs()
            result.success(logs)
        } catch (e: Exception) {
            result.success("[]")
        }
    }

    private fun handleClearRequestLogs(result: Result) {
        try {
            Mobile.clearLocalServerRequestLogs()
            result.success(null)
        } catch (e: Exception) {
            result.error("CLEAR_ERROR", e.message, null)
        }
    }

    private fun handleListDirectory(call: MethodCall, result: Result) {
        val path = call.argument<String>("path")

        if (path.isNullOrEmpty()) {
            result.error("INVALID_PATH", "Path is required", null)
            return
        }

        try {
            val files = Mobile.listDirectory(path)
            result.success(files)
        } catch (e: Exception) {
            result.error("LIST_ERROR", e.message, null)
        }
    }

    // ========================================================================
    // Service Methods
    // ========================================================================

    private fun handleIsServiceRunning(result: Result) {
        result.success(CloudflaredService.isServiceRunning())
    }

    private fun handleStopService(result: Result) {
        val context = applicationContext
        if (context != null && serviceBound) {
            try {
                context.unbindService(serviceConnection)
            } catch (e: Exception) {
                // Ignore
            }
            serviceBound = false
        }

        // Force cleanup tunnel and server
        cloudflaredService?.forceCleanupTunnel()
        cloudflaredService?.forceCleanupServer()

        // Force reset Go runtime state including Prometheus metrics
        try {
            Mobile.forceReset()
        } catch (e: Exception) {
            // Ignore - forceReset already handles cleanup
        }

        val stopIntent = Intent(context, CloudflaredService::class.java).apply {
            action = CloudflaredService.ACTION_STOP_SERVICE
        }
        context?.startService(stopIntent)

        result.success(null)
    }

    // ========================================================================
    // Permission Methods
    // ========================================================================

    private fun handleRequestNotificationPermission(result: Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            // Permission not needed on older Android versions
            result.success(true)
            return
        }

        val context = applicationContext ?: run {
            result.success(false)
            return
        }

        if (ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS)
            == PackageManager.PERMISSION_GRANTED) {
            result.success(true)
            return
        }

        val currentActivity = activity ?: run {
            result.success(false)
            return
        }

        pendingPermissionResult = result
        ActivityCompat.requestPermissions(
            currentActivity,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            NOTIFICATION_PERMISSION_REQUEST_CODE
        )
    }

    private fun handleHasNotificationPermission(result: Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(true)
            return
        }

        val context = applicationContext ?: run {
            result.success(false)
            return
        }

        val hasPermission = ContextCompat.checkSelfPermission(
            context, Manifest.permission.POST_NOTIFICATIONS
        ) == PackageManager.PERMISSION_GRANTED

        result.success(hasPermission)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ): Boolean {
        if (requestCode == NOTIFICATION_PERMISSION_REQUEST_CODE) {
            val granted = grantResults.isNotEmpty() &&
                    grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingPermissionResult?.success(granted)
            pendingPermissionResult = null
            return true
        }
        return false
    }

    // ========================================================================
    // Event Handling
    // ========================================================================

    private fun sendEvent(type: String, data: Map<String, Any>) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            eventSink?.success(mapOf("type" to type) + data)
        } else {
            mainHandler.post {
                eventSink?.success(mapOf("type" to type) + data)
            }
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events

        // Sync state when Flutter starts listening
        syncServiceState()
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)

        // Unbind but don't stop service - it should keep running!
        val context = applicationContext
        if (context != null && serviceBound) {
            try {
                context.unbindService(serviceConnection)
            } catch (e: Exception) {
                // Ignore
            }
            serviceBound = false
        }

        applicationContext = null
    }

    // ========================================================================
    // ActivityAware Implementation
    // ========================================================================

    private var activityBinding: ActivityPluginBinding? = null

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        activity = null
    }
}
