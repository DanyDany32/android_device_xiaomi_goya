/*
 * SPDX-FileCopyrightText: 2025 Paranoid Android
 * SPDX-FileCopyrightText: 2026 The LineageOS Project
 * SPDX-License-Identifier: Apache-2.0
 */

package org.lineageos.esimswitcher

import android.content.Context
import android.telephony.SubscriptionManager
import android.util.Log
import java.io.File

class EsimController private constructor(private val context: Context) {

    companion object {
        private const val TAG = "EsimController"
        private const val STATE_TIMEOUT_MS = 3000L

        @Volatile private var instance: EsimController? = null
        fun getInstance(context: Context): EsimController =
            instance ?: synchronized(this) {
                instance ?: EsimController(context.applicationContext).also { instance = it }
            }
    }

    fun onBootCompleted() {
        Log.d(TAG, "onBootCompleted")
    }

    fun getEsimActive(): Boolean {
        val subscriptionManager =
            context.getSystemService(Context.TELEPHONY_SUBSCRIPTION_SERVICE) as? SubscriptionManager
        return subscriptionManager?.activeSubscriptionInfoList?.any { it.isEmbedded } ?: false
    }

    fun getEsimEnabled(): Boolean {
        android.os.SystemProperties.set("ctl.start", "esim_state")

        val start = System.currentTimeMillis()
        while (System.currentTimeMillis() - start < STATE_TIMEOUT_MS) {
            val state = android.os.SystemProperties.get("vendor.esim.state", "")
            if (state.isNotEmpty()) {
                Log.i(TAG, "getEsimEnabled state: $state")
                android.os.SystemProperties.set("vendor.esim.state", "")
                val parts = state.split(",").map { it.trim() }
                return parts.getOrNull(1) == "PRESENT"
            }
            Thread.sleep(100)
        }
        Log.e(TAG, "getEsimEnabled: timeout")
        return false
    }

    fun setEsimEnabled(isEnabled: Boolean) {
        Log.i(TAG, "setEsimEnabled: $isEnabled")
        android.os.SystemProperties.set(
            "ctl.start",
            if (isEnabled) "esim_enable" else "esim_disable"
        )
    }

    fun dispose() {
        Log.d(TAG, "dispose")
    }
}
