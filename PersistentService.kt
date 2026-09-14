package com.example.edupay

import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.util.Log
import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.os.SystemClock
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import android.content.pm.ServiceInfo

class PersistentService : Service() {
    companion object {
        const val ALARM_REQUEST_CODE = 1
        const val CHANNEL_ID = "foreground_channel"
        const val CHANNEL_NAME = "EduPay Service"
        const val NOTIFICATION_ID = 1
    }

    override fun onCreate() {
        super.onCreate()
        Log.d("EduPay", "✅ PersistentService lancé silencieusement")
        createNotificationChannel()
        val foregroundServiceType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING or ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC or ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            0
        } else 0
        ServiceCompat.startForeground(this, NOTIFICATION_ID, buildNotification(), foregroundServiceType)
        scheduleAlarmForSelfRestart()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                CHANNEL_NAME,
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "EduPay foreground service channel"
                setShowBadge(false)
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager?.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("EduPay actif")
            .setContentText("Le service tourne en arrière-plan pour les notifications en temps réel.")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Thread {
            while (true) {
                try {
                    if (!isServiceRunning(MyForegroundService::class.java)) {
                        Log.d("EduPay", "🔄 Redémarrage du ForegroundService")
                        val intentFg = Intent(this, MyForegroundService::class.java)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intentFg)
                        } else {
                            startService(intentFg)
                        }
                    }
                    Log.d("EduPay", "Vérification supplémentaire des composants")
                    Thread.sleep(15000)
                } catch (e: Exception) {
                    Log.e("EduPay", "Error in PersistentService loop: ${e.message}")
                }
            }
        }.start()
        return START_STICKY
    }

    private fun isServiceRunning(serviceClass: Class<*>): Boolean {
        val manager = getSystemService(Context.ACTIVITY_SERVICE) as android.app.ActivityManager
        for (service in manager.getRunningServices(Int.MAX_VALUE)) {
            if (serviceClass.name == service.service.className) {
                return true
            }
        }
        return false
    }

    override fun onDestroy() {
        super.onDestroy()
        Log.d("EduPay", "⚠️ PersistentService détruit, redémarrage immédiat...")
        val restartIntent = Intent(this, PersistentService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(restartIntent)
        } else {
            startService(restartIntent)
        }
        val fgIntent = Intent(this, MyForegroundService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(fgIntent)
        } else {
            startService(fgIntent)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun scheduleAlarmForSelfRestart() {
        val alarmManager = getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val restartIntent = Intent(this, PersistentService::class.java)
        val pendingIntent = PendingIntent.getService(this, ALARM_REQUEST_CODE, restartIntent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val interval = 5 * 60 * 1000L
        alarmManager.setRepeating(AlarmManager.ELAPSED_REALTIME_WAKEUP, SystemClock.elapsedRealtime() + interval, interval, pendingIntent)
    }
}