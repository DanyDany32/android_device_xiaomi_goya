/*
 * SPDX-FileCopyrightText: The LineageOS Project
 * SPDX-License-Identifier: Apache-2.0
 */

package com.xiaomi.settings.fingerprint

import android.os.Bundle

import com.android.settingslib.widget.SettingsBasePreferenceFragment

import com.xiaomi.settings.R

class FingerprintSettingsFragment : SettingsBasePreferenceFragment() {

    override fun onCreatePreferences(savedInstanceState: Bundle?, rootKey: String?) {
        setPreferencesFromResource(R.xml.fingerprint_preferences, rootKey)
    }
}
