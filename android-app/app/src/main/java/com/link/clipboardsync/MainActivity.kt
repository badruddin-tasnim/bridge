package com.link.clipboardsync

import android.Manifest
import android.animation.ObjectAnimator
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.ColorStateList
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.text.Editable
import android.text.TextWatcher
import android.view.View
import android.view.animation.AccelerateDecelerateInterpolator
import android.widget.Button
import android.widget.EditText
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanIntentResult
import com.journeyapps.barcodescanner.ScanOptions
import org.json.JSONObject

class MainActivity : AppCompatActivity(), NetworkSyncClient.SyncListener, ClipboardSyncManager.HistoryListener, UpdateChecker.UpdateListener {

    // Header views
    private lateinit var dotStatus: View
    private lateinit var tvStatusPill: TextView
    private var dotBlinkAnimator: ObjectAnimator? = null

    // Update notification banner
    private lateinit var layoutUpdateBanner: LinearLayout
    private lateinit var tvUpdateTitle: TextView
    private lateinit var btnUpdateDownload: Button
    private lateinit var btnDismissUpdate: ImageView
    private var currentUpdateUrl: String? = null

    // Service notice (Accessibility)
    private lateinit var layoutServiceNotice: LinearLayout
    private lateinit var btnEnableAccessibility: Button

    // Service notice (Notification Listener)
    private lateinit var layoutNotificationNotice: LinearLayout
    private lateinit var btnEnableNotificationAccess: Button

    // Screen A: Connected
    private lateinit var layoutScreenConnected: LinearLayout
    private lateinit var heroCard: LinearLayout
    private lateinit var tvHeroTitle: TextView
    private lateinit var tvHeroSub: TextView
    private lateinit var linkViewHero: BridgeLinkView
    private lateinit var tvDevicePhoneName: TextView
    private lateinit var tvDeviceMacName: TextView
    private lateinit var tvLiveBadge: TextView
    private lateinit var cardNotificationFeature: LinearLayout
    private lateinit var tvNotificationStatus: TextView
    private lateinit var btnHeroConnect: Button
    private lateinit var btnHeroUnpair: Button

    // Screen B: Pairing
    private lateinit var layoutScreenPairing: LinearLayout
    private lateinit var linkViewPairing: BridgeLinkView
    private lateinit var tvPairingTitle: TextView
    private lateinit var tvPairingSub: TextView
    private lateinit var layoutNoteBanner: LinearLayout
    private lateinit var dotNote: View
    private lateinit var tvNoteText: TextView
    private lateinit var btnScanQr: Button
    private lateinit var etPairCode: EditText
    private val codeBoxes = ArrayList<TextView>()
    private lateinit var tvToggleManualIp: TextView
    private lateinit var layoutManualIp: LinearLayout
    private lateinit var etServerIp: EditText
    private lateinit var etServerPort: EditText
    private lateinit var btnPair: Button
    private lateinit var btnUnpairPairing: Button

    // Colors
    private val colorInk = Color.parseColor("#0E0F12")
    private val colorLime = Color.parseColor("#C8F135")
    private val colorCoral = Color.parseColor("#FF9A8A")
    private val colorMuted = Color.parseColor("#9BA3AD")
    private val colorText = Color.parseColor("#F4F5F2")

    // QR Code Scanner Launcher
    private val qrScannerLauncher = registerForActivityResult(ScanContract()) { result: ScanIntentResult ->
        if (result.contents != null) {
            handleScannedQr(result.contents)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        initViews()
        setupListeners()
        checkPermissions()

        ClipboardSyncManager.init(this)
        BridgeNotificationManager.init(this)
        ClipboardSyncForegroundService.start(this)
    }

    override fun onResume() {
        super.onResume()
        ClipboardSyncManager.init(this)
        ClipboardSyncManager.addHistoryListener(this)
        ClipboardSyncManager.networkClient?.addListener(this)
        UpdateChecker.addListener(this, this)
        UpdateChecker.checkForUpdates(this, forceNetwork = false)

        updateAccessibilityNotice()
        updateUI()

        if (!BridgePrefs.isPaired(this)) {
            ClipboardSyncManager.networkClient?.startDiscovery()
        }
    }

    override fun onPause() {
        super.onPause()
        ClipboardSyncManager.networkClient?.removeListener(this)
        ClipboardSyncManager.removeHistoryListener(this)
        UpdateChecker.removeListener(this)
    }

    private fun initViews() {
        // Header
        dotStatus = findViewById(R.id.dotStatus)
        tvStatusPill = findViewById(R.id.tvStatusPill)

        // Update Banner
        layoutUpdateBanner = findViewById(R.id.layoutUpdateBanner)
        tvUpdateTitle = findViewById(R.id.tvUpdateTitle)
        btnUpdateDownload = findViewById(R.id.btnUpdateDownload)
        btnDismissUpdate = findViewById(R.id.btnDismissUpdate)

        // Accessibility service notice
        layoutServiceNotice = findViewById(R.id.layoutServiceNotice)
        btnEnableAccessibility = findViewById(R.id.btnEnableAccessibility)

        // Notification Access notice
        layoutNotificationNotice = findViewById(R.id.layoutNotificationNotice)
        btnEnableNotificationAccess = findViewById(R.id.btnEnableNotificationAccess)

        // Screen A
        layoutScreenConnected = findViewById(R.id.layoutScreenConnected)
        heroCard = findViewById(R.id.heroCard)
        tvHeroTitle = findViewById(R.id.tvHeroTitle)
        tvHeroSub = findViewById(R.id.tvHeroSub)
        linkViewHero = findViewById(R.id.linkViewHero)
        tvDevicePhoneName = findViewById(R.id.tvDevicePhoneName)
        tvDeviceMacName = findViewById(R.id.tvDeviceMacName)
        tvLiveBadge = findViewById(R.id.tvLiveBadge)
        cardNotificationFeature = findViewById(R.id.cardNotificationFeature)
        tvNotificationStatus = findViewById(R.id.tvNotificationStatus)
        btnHeroConnect = findViewById(R.id.btnHeroConnect)
        btnHeroUnpair = findViewById(R.id.btnHeroUnpair)

        // Screen B
        layoutScreenPairing = findViewById(R.id.layoutScreenPairing)
        linkViewPairing = findViewById(R.id.linkViewPairing)
        tvPairingTitle = findViewById(R.id.tvPairingTitle)
        tvPairingSub = findViewById(R.id.tvPairingSub)
        layoutNoteBanner = findViewById(R.id.layoutNoteBanner)
        dotNote = findViewById(R.id.dotNote)
        tvNoteText = findViewById(R.id.tvNoteText)
        btnScanQr = findViewById(R.id.btnScanQr)
        etPairCode = findViewById(R.id.etPairCode)

        codeBoxes.clear()
        codeBoxes.add(findViewById(R.id.tvCode0))
        codeBoxes.add(findViewById(R.id.tvCode1))
        codeBoxes.add(findViewById(R.id.tvCode2))
        codeBoxes.add(findViewById(R.id.tvCode3))
        codeBoxes.add(findViewById(R.id.tvCode4))
        codeBoxes.add(findViewById(R.id.tvCode5))

        tvToggleManualIp = findViewById(R.id.tvToggleManualIp)
        layoutManualIp = findViewById(R.id.layoutManualIp)
        etServerIp = findViewById(R.id.etServerIp)
        etServerPort = findViewById(R.id.etServerPort)
        btnPair = findViewById(R.id.btnPair)
        btnUnpairPairing = findViewById(R.id.btnUnpairPairing)

        // Real Phone Model Name (e.g., Galaxy A52s)
        val phoneModel = Build.MODEL.let {
            if (it.startsWith(Build.MANUFACTURER, ignoreCase = true)) it
            else "${Build.MANUFACTURER.replaceFirstChar { c -> c.uppercase() }} $it"
        }
        tvDevicePhoneName.text = phoneModel

        // Prefill server IP if saved
        BridgePrefs.host(this)?.let { etServerIp.setText(it) }
        BridgePrefs.port(this).let { etServerPort.setText(it.toString()) }
    }

    private fun setupListeners() {
        btnUpdateDownload.setOnClickListener {
            val url = currentUpdateUrl ?: "https://github.com/badruddin-tasnim/bridge/releases/latest"
            try {
                startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
            } catch (ignored: Exception) {}
        }

        btnDismissUpdate.setOnClickListener {
            UpdateChecker.dismissUpdateForToday(this)
            layoutUpdateBanner.visibility = View.GONE
        }

        btnEnableAccessibility.setOnClickListener {
            startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
        }

        btnEnableNotificationAccess.setOnClickListener {
            startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
        }

        cardNotificationFeature.setOnClickListener {
            startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
        }

        btnScanQr.setOnClickListener {
            val options = ScanOptions().apply {
                setPrompt("Point camera at the QR code in the Mac menu bar")
                setBeepEnabled(false)
                setOrientationLocked(true)
                setCaptureActivity(PortraitCaptureActivity::class.java)
                setBarcodeImageEnabled(false)
                setDesiredBarcodeFormats(ScanOptions.QR_CODE)
            }
            qrScannerLauncher.launch(options)
        }

        tvToggleManualIp.setOnClickListener {
            if (layoutManualIp.visibility == View.VISIBLE) {
                layoutManualIp.visibility = View.GONE
                tvToggleManualIp.text = "Enter IP address instead"
            } else {
                layoutManualIp.visibility = View.VISIBLE
                tvToggleManualIp.text = "Hide IP address setup"
            }
        }

        etPairCode.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
            override fun afterTextChanged(s: Editable?) {
                val clean = s?.toString()?.replace(" ", "")?.replace("-", "") ?: ""
                updateCodeBoxes(clean)
                val isReady = clean.length == 6
                btnPair.isEnabled = isReady
                btnPair.alpha = if (isReady) 1.0f else 0.45f

                if (isReady && btnPair.isEnabled && !isConnectingState) {
                    btnPair.performClick()
                }
            }
        })

        // Clicking on any box focuses the hidden EditText
        val focusInputListener = View.OnClickListener {
            etPairCode.requestFocus()
            val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as? android.view.inputmethod.InputMethodManager
            imm?.showSoftInput(etPairCode, android.view.inputmethod.InputMethodManager.SHOW_IMPLICIT)
        }
        findViewById<View>(R.id.layoutCodeBoxes).setOnClickListener(focusInputListener)
        for (box in codeBoxes) {
            box.setOnClickListener(focusInputListener)
        }

        btnPair.setOnClickListener {
            val rawCode = etPairCode.text.toString().trim()
            val code = rawCode.replace(" ", "").replace("-", "")
            if (code.length != 6) {
                showPairingNote("Please enter a 6-digit code.", BannerStyle.ERROR)
                return@setOnClickListener
            }

            var host = etServerIp.text.toString().trim()
            if (host.isEmpty()) {
                host = BridgePrefs.host(this) ?: ""
            }
            val port = etServerPort.text.toString().toIntOrNull() ?: NetworkSyncClient.DEFAULT_PORT

            setConnectingState(true)
            showPairingNote("Looking for your Mac on this Wi-Fi…", BannerStyle.CONNECTING)

            val hostParam = host.ifEmpty { null }
            ClipboardSyncManager.pair(this, hostParam, port, code)
        }

        btnUnpairPairing.setOnClickListener {
            ClipboardSyncManager.unpair(this)
            etPairCode.setText("")
            setConnectingState(false)
            updateUI()
            Toast.makeText(this, "Unpaired successfully", Toast.LENGTH_SHORT).show()
        }

        btnHeroConnect.setOnClickListener {
            setConnectingState(true)
            ClipboardSyncManager.networkClient?.start(
                BridgePrefs.host(this),
                BridgePrefs.port(this),
                BridgePrefs.code(this)
            )
        }

        btnHeroUnpair.setOnClickListener {
            ClipboardSyncManager.unpair(this)
            etPairCode.setText("")
            setConnectingState(false)
            updateUI()
            Toast.makeText(this, "Unpaired successfully", Toast.LENGTH_SHORT).show()
        }
    }

    private var isConnectingState = false

    private fun updateCodeBoxes(value: String) {
        val activeIndex = value.length.coerceAtMost(5)
        for (i in 0 until 6) {
            val box = codeBoxes[i]
            if (i < value.length) {
                box.text = value[i].toString()
            } else {
                box.text = ""
            }
            if (i == activeIndex && etPairCode.isFocused) {
                box.setBackgroundResource(R.drawable.bg_code_box_active)
            } else {
                box.setBackgroundResource(R.drawable.bg_code_box)
            }
        }
    }

    private fun handleScannedQr(qrData: String) {
        try {
            if (qrData.trim().startsWith("{")) {
                val json = JSONObject(qrData)
                val code = json.optString("code")
                val ip = json.optString("ip").ifEmpty { null }
                val port = json.optInt("port", NetworkSyncClient.DEFAULT_PORT)
                val name = json.optString("name", "Mac")

                if (code.isNotEmpty()) {
                    etPairCode.setText(code)
                    setConnectingState(true)
                    showPairingNote("Looking for your Mac on this Wi-Fi…", BannerStyle.CONNECTING)
                    ClipboardSyncManager.pair(this, ip, port, code)
                    return
                }
            }

            val cleanCode = qrData.replace(" ", "").replace("-", "").trim()
            if (cleanCode.length == 6 && cleanCode.all { it.isDigit() }) {
                etPairCode.setText(cleanCode)
                btnPair.performClick()
                return
            }

            showPairingNote("Unrecognized QR code format.", BannerStyle.ERROR)
        } catch (e: Exception) {
            showPairingNote("Couldn't reach your Mac. Check that you're on the same Wi-Fi and Bridge is open on it.", BannerStyle.ERROR)
        }
    }

    private fun setConnectingState(connecting: Boolean) {
        isConnectingState = connecting
        if (connecting) {
            tvStatusPill.text = "Linking…"
            tvStatusPill.setTextColor(colorLime)
            dotStatus.backgroundTintList = ColorStateList.valueOf(colorLime)
            startDotBlink()

            linkViewHero.setMode(BridgeLinkView.LinkMode.HERO_CONNECTING)
            linkViewPairing.setMode(BridgeLinkView.LinkMode.PAIRING_CONNECTING)
            btnPair.isEnabled = false
            btnPair.text = "Connecting…"
            btnHeroConnect.isEnabled = false
            btnHeroConnect.text = "Connecting…"
        } else {
            stopDotBlink()
            btnPair.text = "Connect"
            btnPair.isEnabled = etPairCode.text.toString().replace(" ", "").length == 6
        }
    }

    private fun startDotBlink() {
        if (dotBlinkAnimator == null) {
            dotBlinkAnimator = ObjectAnimator.ofFloat(dotStatus, "alpha", 1.0f, 0.2f, 1.0f).apply {
                duration = 700
                repeatCount = ObjectAnimator.INFINITE
                interpolator = AccelerateDecelerateInterpolator()
                start()
            }
        }
    }

    private fun stopDotBlink() {
        dotBlinkAnimator?.cancel()
        dotBlinkAnimator = null
        dotStatus.alpha = 1.0f
    }

    enum class BannerStyle { ERROR, CONNECTING, CONNECTED }

    private fun showPairingNote(message: String, style: BannerStyle) {
        layoutNoteBanner.visibility = View.VISIBLE
        tvNoteText.text = message
        when (style) {
            BannerStyle.ERROR -> {
                layoutNoteBanner.setBackgroundResource(R.drawable.bg_note_error)
                dotNote.backgroundTintList = ColorStateList.valueOf(colorCoral)
                tvNoteText.setTextColor(colorCoral)
            }
            BannerStyle.CONNECTING -> {
                layoutNoteBanner.setBackgroundResource(R.drawable.bg_note_connecting)
                dotNote.backgroundTintList = ColorStateList.valueOf(colorMuted)
                tvNoteText.setTextColor(colorMuted)
            }
            BannerStyle.CONNECTED -> {
                layoutNoteBanner.setBackgroundResource(R.drawable.bg_note_connected)
                dotNote.backgroundTintList = ColorStateList.valueOf(colorLime)
                tvNoteText.setTextColor(colorLime)
            }
        }
    }

    private fun updateAccessibilityNotice() {
        if (isAccessibilityServiceEnabled()) {
            layoutServiceNotice.visibility = View.GONE
        } else {
            layoutServiceNotice.visibility = View.VISIBLE
        }

        if (isNotificationServiceEnabled()) {
            layoutNotificationNotice.visibility = View.GONE
        } else {
            layoutNotificationNotice.visibility = View.VISIBLE
        }
    }

    private fun isNotificationServiceEnabled(): Boolean {
        val flat = Settings.Secure.getString(contentResolver, "enabled_notification_listeners") ?: return false
        val expected = "${packageName}/${BridgeNotificationListenerService::class.java.canonicalName}"
        return flat.split(':').any { it.equals(expected, ignoreCase = true) || it.contains(packageName) }
    }

    private fun isAccessibilityServiceEnabled(): Boolean {
        val expectedService = "${packageName}/${ClipboardSyncAccessibilityService::class.java.canonicalName}"
        val enabledServices = Settings.Secure.getString(contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: return false
        return enabledServices.split(':').any { it.equals(expectedService, ignoreCase = true) }
    }

    private fun updateUI() {
        val paired = BridgePrefs.isPaired(this)
        val connected = ClipboardSyncManager.networkClient?.isConnected() == true
        val macName = BridgePrefs.macName(this) ?: "Mac"

        if (paired) {
            layoutScreenPairing.visibility = View.GONE
            layoutScreenConnected.visibility = View.VISIBLE
            tvDeviceMacName.text = macName

            if (isNotificationServiceEnabled()) {
                tvNotificationStatus.text = "Active"
                tvNotificationStatus.setTextColor(colorLime)
            } else {
                tvNotificationStatus.text = "Tap to Enable"
                tvNotificationStatus.setTextColor(colorCoral)
            }

            if (connected) {
                isConnectingState = false
                stopDotBlink()

                // Header status pill
                tvStatusPill.text = "Linked"
                tvStatusPill.setTextColor(colorLime)
                dotStatus.backgroundTintList = ColorStateList.valueOf(colorLime)

                // Hero card (Lime)
                heroCard.setBackgroundResource(R.drawable.bg_card_lime)
                tvHeroTitle.text = "Phone and Mac connected!"
                tvHeroTitle.setTextColor(colorInk)
                tvHeroSub.visibility = View.GONE
                linkViewHero.setMode(BridgeLinkView.LinkMode.HERO_CONNECTED)

                // Devices card
                tvLiveBadge.text = "Live"
                tvLiveBadge.setTextColor(colorLime)

                // Bottom CTAs
                btnHeroConnect.visibility = View.GONE
                btnHeroUnpair.visibility = View.VISIBLE
                btnHeroUnpair.isEnabled = true
            } else {
                // Paired but not connected (Idle or Reconnecting)
                if (isConnectingState) {
                    tvStatusPill.text = "Linking…"
                    tvStatusPill.setTextColor(colorLime)
                    dotStatus.backgroundTintList = ColorStateList.valueOf(colorLime)
                    startDotBlink()

                    heroCard.setBackgroundResource(R.drawable.bg_card_panel)
                    tvHeroTitle.text = "Finding your Mac…"
                    tvHeroTitle.setTextColor(colorText)
                    tvHeroSub.text = "Looking on your Wi-Fi. This only takes a moment."
                    tvHeroSub.setTextColor(colorMuted)
                    linkViewHero.setMode(BridgeLinkView.LinkMode.HERO_CONNECTING)

                    tvLiveBadge.text = "Searching"
                    tvLiveBadge.setTextColor(colorMuted)

                    btnHeroConnect.visibility = View.VISIBLE
                    btnHeroConnect.isEnabled = false
                    btnHeroConnect.text = "Connecting…"
                    btnHeroConnect.setTextColor(colorMuted)
                    btnHeroConnect.setBackgroundResource(R.drawable.bg_button_outline)

                    btnHeroUnpair.visibility = View.VISIBLE
                    btnHeroUnpair.isEnabled = true
                } else {
                    stopDotBlink()
                    tvStatusPill.text = "Not linked"
                    tvStatusPill.setTextColor(colorMuted)
                    dotStatus.backgroundTintList = ColorStateList.valueOf(colorMuted)

                    heroCard.setBackgroundResource(R.drawable.bg_card_panel)
                    tvHeroTitle.text = "Not connected."
                    tvHeroTitle.setTextColor(colorText)
                    tvHeroSub.text = "Your Mac isn't paired right now. Reconnect to pick up where you left off."
                    tvHeroSub.setTextColor(colorMuted)
                    linkViewHero.setMode(BridgeLinkView.LinkMode.HERO_IDLE)

                    tvLiveBadge.text = "Offline"
                    tvLiveBadge.setTextColor(colorMuted)

                    btnHeroConnect.visibility = View.VISIBLE
                    btnHeroConnect.isEnabled = true
                    btnHeroConnect.text = "Connect to Mac"
                    btnHeroConnect.setTextColor(colorInk)
                    btnHeroConnect.setBackgroundResource(R.drawable.bg_button_lime)

                    btnHeroUnpair.visibility = View.VISIBLE
                    btnHeroUnpair.isEnabled = true
                }
            }
        } else {
            // Not Paired (Screen B) - no Mac is paired, so hide Unpair button
            layoutScreenConnected.visibility = View.GONE
            layoutScreenPairing.visibility = View.VISIBLE
            btnUnpairPairing.visibility = View.GONE

            if (isConnectingState) {
                tvStatusPill.text = "Linking…"
                tvStatusPill.setTextColor(colorLime)
                dotStatus.backgroundTintList = ColorStateList.valueOf(colorLime)
                startDotBlink()

                linkViewPairing.setMode(BridgeLinkView.LinkMode.PAIRING_CONNECTING)
                btnPair.isEnabled = false
                btnPair.text = "Connecting…"
            } else {
                stopDotBlink()
                tvStatusPill.text = "Not linked"
                tvStatusPill.setTextColor(colorMuted)
                dotStatus.backgroundTintList = ColorStateList.valueOf(colorMuted)

                linkViewPairing.setMode(BridgeLinkView.LinkMode.PAIRING_IDLE)
                val clean = etPairCode.text.toString().replace(" ", "").replace("-", "")
                btnPair.text = "Connect"
                btnPair.isEnabled = clean.length == 6
                btnPair.alpha = if (clean.length == 6) 1.0f else 0.45f
            }
        }
    }

    // MARK: - SyncListener Implementation

    override fun onConnectionStatusChanged(isConnected: Boolean, host: String?) {
        runOnUiThread {
            isConnectingState = false
            updateUI()
        }
    }

    override fun onPairingResult(accepted: Boolean, macName: String?) {
        runOnUiThread {
            isConnectingState = false
            if (accepted) {
                showPairingNote("Connected. You're all set.", BannerStyle.CONNECTED)
                updateUI()
            } else {
                showPairingNote("Couldn't reach your Mac. Check that you're on the same Wi-Fi and Bridge is open on it.", BannerStyle.ERROR)
                updateUI()
            }
        }
    }

    override fun onRemoteUnpair() {
        runOnUiThread {
            isConnectingState = false
            etPairCode.setText("")
            layoutNoteBanner.visibility = View.GONE
            updateUI()
            Toast.makeText(this, "Unpaired from Mac", Toast.LENGTH_SHORT).show()
        }
    }

    override fun onPayloadReceived(payload: ClipboardPayload) {
        // Background sync only, UI feed removed per specification
    }

    override fun onLog(message: String) {
        // Internal diagnostic log - map connection failures to friendly design copy
        runOnUiThread {
            if (message.contains("Connection dropped or failed") || message.contains("Socket closed") || message.contains("failed")) {
                if (!BridgePrefs.isPaired(this)) {
                    isConnectingState = false
                    showPairingNote("Couldn't reach your Mac. Check that you're on the same Wi-Fi and Bridge is open on it.", BannerStyle.ERROR)
                    updateUI()
                }
            }
        }
    }

    // MARK: - HistoryListener

    override fun onHistoryChanged() {
        // Feed removed per design specification
    }

    // MARK: - UpdateListener

    override fun onUpdateStateChanged(update: UpdateChecker.UpdateInfo?) {
        runOnUiThread {
            if (update != null) {
                currentUpdateUrl = update.downloadUrl
                tvUpdateTitle.text = "Bridge v${update.version} is available"
                layoutUpdateBanner.visibility = View.VISIBLE
            } else {
                layoutUpdateBanner.visibility = View.GONE
            }
        }
    }

    private fun checkPermissions() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), 101)
            }
        }

        try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            if (!pm.isIgnoringBatteryOptimizations(packageName)) {
                val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                    data = Uri.parse("package:$packageName")
                }
                startActivity(intent)
            }
        } catch (ignored: Exception) {}
    }
}
