package com.linkos.features.nfc

import android.os.Bundle
import android.widget.Toast
import androidx.fragment.app.FragmentActivity
import com.linkos.core.security.BiometricAuth
import dagger.hilt.android.AndroidEntryPoint
import javax.inject.Inject

@AndroidEntryPoint
class NFCActivity : FragmentActivity() {

    @Inject
    lateinit var biometricAuth: BiometricAuth

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Trigger biometric unlock prompt on NFC tag scan
        biometricAuth.authenticate(
            activity = this,
            title = "LinkOS NFC Authenticate",
            subtitle = "Approve NFC tap action for Mac",
            onSuccess = {
                Toast.makeText(this, "NFC Action Authenticated & Sent to Mac", Toast.LENGTH_SHORT).show()
                finish()
            },
            onError = { err ->
                Toast.makeText(this, "Authentication failed: $err", Toast.LENGTH_SHORT).show()
                finish()
            }
        )
    }
}
