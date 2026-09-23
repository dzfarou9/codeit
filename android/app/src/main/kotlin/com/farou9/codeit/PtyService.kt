package com.farou9.codeit

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * PtyService — Foreground Service that keeps the PRoot/PTY process alive.
 *
 * Android 12+ Phantom Process Killer aggressively kills child processes of
 * backgrounded apps. Running the PTY inside a foreground service with a
 * persistent notification prevents this.
 *
 * MainActivity starts this service before calling PtyBridge.start().
 * The service itself does NOT own the PTY fd — PtyBridge (in the Activity
 * process) does. The service's existence alone keeps the process importance
 * at FOREGROUND, which exempts children from the killer.
 *
 * If the Activity is destroyed, the service continues until explicitly stopped.
 */
class PtyService : Service() {

    companion object {
        private const val CHANNEL_ID = "codeit_pty"
        private const val NOTIF_ID = 1001

        fun start(context: Context) {
            val intent = Intent(context, PtyService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, PtyService::class.java))
        }
    }

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(NOTIF_ID, buildNotification())
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "codeit Linux Session",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Keeps the Linux terminal session alive"
                setShowBadge(false)
            }
            val nm = getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("codeit — Linux session active")
            .setContentText("Tap to return to the terminal")
            .setSmallIcon(android.R.drawable.ic_menu_manage)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            // Intent to bring MainActivity to front
            .setContentIntent(
                android.app.PendingIntent.getActivity(
                    this, 0,
                    Intent(this, MainActivity::class.java).apply {
                        flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                    },
                    android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE,
                )
            )
            .build()
    }
}
