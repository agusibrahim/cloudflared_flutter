package com.cloudflare.cloudflared_tunnel

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Binder
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import mobile.Mobile
import mobile.TunnelCallback as GoTunnelCallback
import mobile.ServerCallback as GoServerCallback
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Foreground service that keeps the cloudflared tunnel and local server running
 * even when the app is closed or removed from recent apps.
 *
 * Similar to Termux's approach - the service survives app closure and notification dismissal.
 */
class CloudflaredService : Service() {

    companion object {
        const val CHANNEL_ID = "cloudflared_tunnel_service"
        const val NOTIFICATION_ID = 1001
        const val ACTION_STOP_SERVICE = "com.cloudflare.cloudflared_tunnel.STOP_SERVICE"

        // Service state - static to survive app restarts
        @Volatile
        var isTunnelRunning = false
            private set

        @Volatile
        var isServerRunning = false
            private set

        @Volatile
        var currentTunnelState = 0
            private set

        @Volatile
        var currentServerState = 0
            private set

        @Volatile
        var lastTunnelToken: String? = null
            private set

        @Volatile
        var lastOriginUrl: String? = null
            private set

        @Volatile
        var lastServerRootDir: String? = null
            private set

        @Volatile
        var lastServerPort: Int = 8080
            private set

        private var instance: CloudflaredService? = null

        fun getInstance(): CloudflaredService? = instance

        fun isServiceRunning(): Boolean = instance != null
    }

    private val binder = LocalBinder()
    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var wakeLock: PowerManager.WakeLock? = null

    // Callbacks for Flutter plugin
    var tunnelEventCallback: ((String, Map<String, Any>) -> Unit)? = null
    var serverEventCallback: ((String, Map<String, Any>) -> Unit)? = null

    inner class LocalBinder : Binder() {
        fun getService(): CloudflaredService = this@CloudflaredService
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        createNotificationChannel()
        acquireWakeLock()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP_SERVICE -> {
                stopTunnel()
                stopServer()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
        }

        // Start as foreground service immediately
        startForeground(NOTIFICATION_ID, createNotification())

        return START_STICKY // Restart service if killed
    }

    override fun onBind(intent: Intent?): IBinder {
        return binder
    }

    override fun onDestroy() {
        super.onDestroy()
        releaseWakeLock()
        instance = null
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // App was swiped from recent apps - keep service running!
        // This is the key to Termux-like behavior
        super.onTaskRemoved(rootIntent)

        // Update notification to show we're still running
        if (isTunnelRunning || isServerRunning) {
            updateNotification("Running in background")
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Cloudflared Tunnel Service",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Keeps cloudflared tunnel running in background"
                setShowBadge(false)
            }

            val notificationManager = getSystemService(NotificationManager::class.java)
            notificationManager.createNotificationChannel(channel)
        }
    }

    private fun createNotification(status: String = "Service running"): Notification {
        // Intent to open the app
        val packageName = applicationContext.packageName
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingLaunchIntent = if (launchIntent != null) {
            PendingIntent.getActivity(
                this, 0, launchIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        } else null

        // Intent to stop service
        val stopIntent = Intent(this, CloudflaredService::class.java).apply {
            action = ACTION_STOP_SERVICE
        }
        val pendingStopIntent = PendingIntent.getService(
            this, 0, stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val statusText = buildString {
            if (isTunnelRunning) append("Tunnel: Connected")
            else if (currentTunnelState == 1) append("Tunnel: Connecting...")

            if (isServerRunning) {
                if (isNotEmpty()) append(" | ")
                append("Server: Running")
            }

            if (isEmpty()) append(status)
        }

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Cloudflared")
            .setContentText(statusText)
            .setSmallIcon(android.R.drawable.ic_menu_share)
            .setOngoing(true) // Cannot be dismissed
            .setShowWhen(false)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setContentIntent(pendingLaunchIntent)
            .addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                "Stop",
                pendingStopIntent
            )
            .build()
    }

    fun updateNotification(status: String? = null) {
        val notification = createNotification(status ?: "Running")
        val notificationManager = getSystemService(NotificationManager::class.java)
        notificationManager.notify(NOTIFICATION_ID, notification)
    }

    private fun acquireWakeLock() {
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "cloudflared::TunnelWakeLock"
        ).apply {
            acquire()
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.let {
            if (it.isHeld) {
                it.release()
            }
        }
        wakeLock = null
    }

    // ========================================================================
    // Tunnel Methods
    // ========================================================================

    fun startTunnel(token: String, originUrl: String, callback: ((Boolean, String?) -> Unit)? = null) {
        if (isTunnelRunning) {
            callback?.invoke(false, "Tunnel is already running")
            return
        }

        // Force cleanup any previous tunnel state before starting
        forceCleanupTunnel()

        lastTunnelToken = token
        lastOriginUrl = originUrl

        executor.execute {
            try {
                currentTunnelState = 1 // Connecting
                notifyTunnelState(1, "Starting tunnel...")
                updateNotification()

                val goCallback = object : GoTunnelCallback {
                    override fun onStateChanged(state: Long, message: String?) {
                        currentTunnelState = state.toInt()
                        isTunnelRunning = state.toInt() == 2 // Connected
                        mainHandler.post {
                            notifyTunnelState(state.toInt(), message ?: "")
                            updateNotification()
                        }
                    }

                    override fun onError(code: Long, message: String?) {
                        val errorMessage = message ?: "Unknown error"
                        mainHandler.post {
                            // Check if this is a metrics error - need service restart
                            if (errorMessage.contains("metrics") || errorMessage.contains("duplicate") ||
                                errorMessage.contains("already registered")) {
                                notifyTunnelError(code.toInt(),
                                    "Tunnel state error. Please use 'Stop Service' button and try again.")
                            } else {
                                notifyTunnelError(code.toInt(), errorMessage)
                            }
                        }
                    }

                    override fun onLog(level: Long, message: String?) {
                        mainHandler.post {
                            notifyTunnelLog(level.toInt(), message ?: "")
                        }
                    }
                }

                // This blocks until tunnel stops
                Mobile.startTunnelWithCallback(token, originUrl, goCallback)

            } catch (e: Exception) {
                val errorMessage = e.message ?: "Unknown error"
                mainHandler.post {
                    // Check if this is a metrics panic
                    if (errorMessage.contains("metrics") || errorMessage.contains("duplicate") ||
                        errorMessage.contains("panic")) {
                        notifyTunnelError(1,
                            "Tunnel crashed. Please stop the service completely and restart the app.")
                    } else {
                        notifyTunnelError(1, errorMessage)
                    }
                    callback?.invoke(false, errorMessage)
                }
            } finally {
                isTunnelRunning = false
                currentTunnelState = 0
                mainHandler.post {
                    notifyTunnelState(0, "Tunnel stopped")
                    updateNotification()
                    checkAndStopServiceIfIdle()
                }
            }
        }

        callback?.invoke(true, null)
    }

    fun stopTunnel() {
        try {
            Mobile.stopTunnel()
        } catch (e: Exception) {
            // Ignore
        } finally {
            // Always reset state even if stop fails
            isTunnelRunning = false
            currentTunnelState = 0
            lastTunnelToken = null
            lastOriginUrl = null
        }

        // Reset Prometheus metrics for clean restart
        try {
            Mobile.forceReset()
        } catch (e: Exception) {
            // Ignore
        }
    }

    /// Force cleanup all tunnel state - use before starting new tunnel
    fun forceCleanupTunnel() {
        try {
            Mobile.forceReset()
        } catch (e: Exception) {
            // Ignore
        }
        isTunnelRunning = false
        currentTunnelState = 0
        lastTunnelToken = null
        lastOriginUrl = null
    }

    // ========================================================================
    // Server Methods
    // ========================================================================

    fun startServer(rootDir: String, port: Int, callback: ((Boolean, String?) -> Unit)? = null) {
        if (isServerRunning) {
            callback?.invoke(false, "Server is already running")
            return
        }

        lastServerRootDir = rootDir
        lastServerPort = port

        try {
            val goCallback = object : GoServerCallback {
                override fun onServerStateChanged(state: Long, message: String?) {
                    currentServerState = state.toInt()
                    isServerRunning = state.toInt() == 2 // Running
                    mainHandler.post {
                        notifyServerState(state.toInt(), message ?: "")
                        updateNotification()
                    }
                }

                override fun onRequestLog(logJson: String?) {
                    mainHandler.post {
                        notifyRequestLog(logJson ?: "{}")
                    }
                }

                override fun onServerError(code: Long, message: String?) {
                    mainHandler.post {
                        notifyServerError(code.toInt(), message ?: "Unknown error")
                    }
                }
            }

            Mobile.startLocalServer(rootDir, port.toLong(), goCallback)
            isServerRunning = true
            updateNotification()
            callback?.invoke(true, null)

        } catch (e: Exception) {
            callback?.invoke(false, e.message)
        }
    }

    fun stopServer() {
        try {
            Mobile.stopLocalServer()
        } catch (e: Exception) {
            // Ignore
        } finally {
            // Always reset state even if stop fails
            isServerRunning = false
            currentServerState = 0
            lastServerRootDir = null
            updateNotification()
            checkAndStopServiceIfIdle()
        }
    }

    /// Force cleanup all server state
    fun forceCleanupServer() {
        try {
            Mobile.stopLocalServer()
        } catch (e: Exception) {
            // Ignore
        }
        isServerRunning = false
        currentServerState = 0
        lastServerRootDir = null
    }

    // ========================================================================
    // Event Notifications
    // ========================================================================

    private fun notifyTunnelState(state: Int, message: String) {
        tunnelEventCallback?.invoke("stateChanged", mapOf("state" to state, "message" to message))
    }

    private fun notifyTunnelError(code: Int, message: String) {
        tunnelEventCallback?.invoke("error", mapOf("code" to code, "message" to message))
    }

    private fun notifyTunnelLog(level: Int, message: String) {
        tunnelEventCallback?.invoke("log", mapOf("level" to level, "message" to message))
    }

    private fun notifyServerState(state: Int, message: String) {
        serverEventCallback?.invoke("serverStateChanged", mapOf("state" to state, "message" to message))
    }

    private fun notifyServerError(code: Int, message: String) {
        serverEventCallback?.invoke("serverError", mapOf("code" to code, "message" to message))
    }

    private fun notifyRequestLog(logJson: String) {
        serverEventCallback?.invoke("requestLog", mapOf("log" to logJson))
    }

    private fun checkAndStopServiceIfIdle() {
        if (!isTunnelRunning && !isServerRunning) {
            // No more work to do, stop service after a short delay
            mainHandler.postDelayed({
                if (!isTunnelRunning && !isServerRunning) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                }
            }, 1000)
        }
    }
}
