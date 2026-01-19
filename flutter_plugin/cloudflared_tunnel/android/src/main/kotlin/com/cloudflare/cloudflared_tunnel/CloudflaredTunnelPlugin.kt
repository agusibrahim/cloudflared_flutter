package com.cloudflare.cloudflared_tunnel

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.util.concurrent.Executors
import mobile.Mobile
import mobile.TunnelCallback as GoTunnelCallback
import mobile.ServerCallback as GoServerCallback

/** CloudflaredTunnelPlugin */
class CloudflaredTunnelPlugin : FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler {
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()

    private var isTunnelRunning = false
    private var isServerRunning = false

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
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

            else -> result.notImplemented()
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

        if (isTunnelRunning) {
            result.error("ALREADY_RUNNING", "Tunnel is already running", null)
            return
        }

        // Start tunnel in background thread
        executor.execute {
            try {
                isTunnelRunning = true
                sendEvent("stateChanged", mapOf("state" to 1, "message" to "Starting tunnel..."))

                // Create callback for Go library
                val callback = object : GoTunnelCallback {
                    override fun onStateChanged(state: Long, message: String?) {
                        mainHandler.post {
                            sendEvent("stateChanged", mapOf(
                                "state" to state.toInt(),
                                "message" to (message ?: "")
                            ))
                        }
                    }

                    override fun onError(code: Long, message: String?) {
                        mainHandler.post {
                            sendEvent("error", mapOf(
                                "code" to code.toInt(),
                                "message" to (message ?: "Unknown error")
                            ))
                        }
                    }

                    override fun onLog(level: Long, message: String?) {
                        mainHandler.post {
                            sendEvent("log", mapOf(
                                "level" to level.toInt(),
                                "message" to (message ?: "")
                            ))
                        }
                    }
                }

                // This blocks until tunnel stops
                Mobile.startTunnelWithCallback(token, originUrl, callback)

            } catch (e: Exception) {
                mainHandler.post {
                    sendEvent("error", mapOf(
                        "code" to 1,
                        "message" to (e.message ?: "Unknown error")
                    ))
                }
            } finally {
                isTunnelRunning = false
                mainHandler.post {
                    sendEvent("stateChanged", mapOf(
                        "state" to 0,
                        "message" to "Tunnel stopped"
                    ))
                }
            }
        }

        // Return immediately, the actual connection status comes via events
        result.success(null)
    }

    private fun handleStop(result: Result) {
        try {
            Mobile.stopTunnel()
            isTunnelRunning = false
            result.success(null)
        } catch (e: Exception) {
            result.error("STOP_ERROR", e.message, null)
        }
    }

    private fun handleGetState(result: Result) {
        try {
            val state = Mobile.getTunnelState()
            result.success(state.toInt())
        } catch (e: Exception) {
            result.success(0) // Return disconnected state on error
        }
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
        try {
            val running = Mobile.isTunnelRunning()
            result.success(running)
        } catch (e: Exception) {
            result.success(false)
        }
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

        if (isServerRunning) {
            result.error("ALREADY_RUNNING", "Server is already running", null)
            return
        }

        try {
            // Create callback for Go library
            val callback = object : GoServerCallback {
                override fun onServerStateChanged(state: Long, message: String?) {
                    mainHandler.post {
                        sendEvent("serverStateChanged", mapOf(
                            "state" to state.toInt(),
                            "message" to (message ?: "")
                        ))
                        isServerRunning = state.toInt() == 2 // ServerRunning = 2
                    }
                }

                override fun onRequestLog(logJson: String?) {
                    mainHandler.post {
                        sendEvent("requestLog", mapOf(
                            "log" to (logJson ?: "{}")
                        ))
                    }
                }

                override fun onServerError(code: Long, message: String?) {
                    mainHandler.post {
                        sendEvent("serverError", mapOf(
                            "code" to code.toInt(),
                            "message" to (message ?: "Unknown error")
                        ))
                    }
                }
            }

            Mobile.startLocalServer(rootDir, port.toLong(), callback)
            isServerRunning = true
            result.success(null)

        } catch (e: Exception) {
            result.error("SERVER_ERROR", e.message, null)
        }
    }

    private fun handleStopServer(result: Result) {
        try {
            Mobile.stopLocalServer()
            isServerRunning = false
            result.success(null)
        } catch (e: Exception) {
            result.error("STOP_ERROR", e.message, null)
        }
    }

    private fun handleGetServerState(result: Result) {
        try {
            val state = Mobile.getLocalServerState()
            result.success(state.toInt())
        } catch (e: Exception) {
            result.success(0) // Return stopped state on error
        }
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
        try {
            val running = Mobile.isLocalServerRunning()
            result.success(running)
        } catch (e: Exception) {
            result.success(false)
        }
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
    // Event Handling
    // ========================================================================

    private fun sendEvent(type: String, data: Map<String, Any>) {
        // Always post to main thread since eventSink must be called from UI thread
        if (Looper.myLooper() == Looper.getMainLooper()) {
            eventSink?.success(mapOf("type" to type) + data)
        } else {
            mainHandler.post {
                eventSink?.success(mapOf("type" to type) + data)
            }
        }
    }

    // EventChannel.StreamHandler implementation
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)

        // Stop tunnel and server when plugin is detached
        try {
            Mobile.stopTunnel()
            Mobile.stopLocalServer()
        } catch (e: Exception) {
            // Ignore
        }
    }
}
