package com.link.clipboardsync

import android.Manifest
import android.animation.AnimatorSet
import android.animation.ObjectAnimator
import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.ColorStateList
import android.graphics.Color
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.text.Editable
import android.text.TextWatcher
import android.view.View
import android.view.animation.AccelerateDecelerateInterpolator
import android.view.animation.DecelerateInterpolator
import android.view.animation.OvershootInterpolator
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.appcompat.widget.SwitchCompat
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanIntentResult
import com.journeyapps.barcodescanner.ScanOptions
import org.json.JSONObject

class MainActivity : AppCompatActivity(), NetworkSyncClient.SyncListener, ClipboardSyncManager.HistoryListener, UpdateChecker.UpdateListener, BridgeNotificationManager.SettingsListener {

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

    // Setup Progress Indicator
    private lateinit var layoutSetupProgress: LinearLayout
    private lateinit var tvSetupProgressStatus: TextView
    private lateinit var tvSetupProgressDetail: TextView

    // Service notice (Accessibility)
    private lateinit var layoutServiceNotice: LinearLayout
    private lateinit var btnEnableAccessibility: Button

    // Service notice (Notification Listener)
    private lateinit var layoutNotificationNotice: LinearLayout
    private lateinit var btnEnableNotificationAccess: Button

    // Screen A: Connected + Bottom Nav Tabs
    private lateinit var layoutScreenConnected: LinearLayout
    private lateinit var layoutTabBridge: LinearLayout
    private lateinit var layoutTabSettings: LinearLayout
    private lateinit var layoutBottomNav: FrameLayout
    private lateinit var viewNavActiveIndicator: View
    private lateinit var navTabHome: LinearLayout
    private lateinit var ivNavHome: ImageView
    private lateinit var tvNavHome: TextView
    private lateinit var navTabSettings: LinearLayout
    private lateinit var ivNavSettings: ImageView
    private lateinit var tvNavSettings: TextView
    private var isSettingsTabSelected = false
    private var isUpdatingSettingsUi = false

    // Tab 1: Home Overview
    private lateinit var heroCard: LinearLayout
    private lateinit var tvHeroTitle: TextView
    private lateinit var tvHeroSub: TextView
    private lateinit var linkViewHero: BridgeLinkView
    private lateinit var layoutHeroCautionBanner: LinearLayout
    private lateinit var dotHeroCaution: View
    private lateinit var tvHeroCautionTitle: TextView
    private lateinit var btnTroubleshootToggle: TextView
    private lateinit var tvHeroCautionText: TextView
    private lateinit var layoutTroubleshootDetails: LinearLayout
    private lateinit var tvDevicePhoneName: TextView
    private lateinit var tvDeviceMacName: TextView
    private lateinit var tvLiveBadge: TextView
    private lateinit var btnHeroConnect: Button

    // Tab 2: Settings Page
    private lateinit var switchNotifMaster: SwitchCompat
    private lateinit var tvNotifMasterPausedNotice: TextView
    private lateinit var layoutNotifSubOptions: LinearLayout
    private lateinit var viewNotifSubAccent: View
    private lateinit var switchAndroidNotif: SwitchCompat
    private lateinit var switchMacNotif: SwitchCompat
    private lateinit var rowPhoneVibrate: LinearLayout
    private lateinit var switchPhoneVibrate: SwitchCompat
    private lateinit var rowSettingNotifAccess: LinearLayout
    private lateinit var tvSettingNotifAccessStatus: TextView
    private lateinit var rowSettingAccessibility: LinearLayout
    private lateinit var tvSettingAccessibilityStatus: TextView
    private lateinit var tvSettingsDeviceMacName: TextView
    private lateinit var tvSettingsDeviceStatus: TextView
    private lateinit var btnUnpairMacSettings: Button

    // Failure / Retry tracking
    private var consecutiveFailures = 0
    private var userConnectAttempts = 0
    private var wasConnectedBefore = false

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

    // Colors
    private val colorInk = Color.parseColor("#0E0F12")
    private val colorLime = Color.parseColor("#C8F135")
    private val colorCoral = Color.parseColor("#FF9A8A")
    private val colorMuted = Color.parseColor("#9BA3AD")
    private val colorSoft = Color.parseColor("#C9CED4")
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
        BridgeNotificationManager.addSettingsListener(this)
        UpdateChecker.addListener(this, this)
        UpdateChecker.checkForUpdates(this, forceNetwork = false)

        updateAccessibilityNotice()
        updateSetupProgress()
        updateUI()

        if (!BridgePrefs.isPaired(this)) {
            ClipboardSyncManager.networkClient?.startDiscovery()
        }
    }

    override fun onPause() {
        super.onPause()
        ClipboardSyncManager.networkClient?.removeListener(this)
        ClipboardSyncManager.removeHistoryListener(this)
        BridgeNotificationManager.removeSettingsListener(this)
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

        // Setup Progress
        layoutSetupProgress = findViewById(R.id.layoutSetupProgress)
        tvSetupProgressStatus = findViewById(R.id.tvSetupProgressStatus)
        tvSetupProgressDetail = findViewById(R.id.tvSetupProgressDetail)

        // Accessibility service notice
        layoutServiceNotice = findViewById(R.id.layoutServiceNotice)
        btnEnableAccessibility = findViewById(R.id.btnEnableAccessibility)

        // Notification Access notice
        layoutNotificationNotice = findViewById(R.id.layoutNotificationNotice)
        btnEnableNotificationAccess = findViewById(R.id.btnEnableNotificationAccess)

        // Screen A & Bottom Nav Tabs
        layoutScreenConnected = findViewById(R.id.layoutScreenConnected)
        layoutTabBridge = findViewById(R.id.layoutTabBridge)
        layoutTabSettings = findViewById(R.id.layoutTabSettings)
        layoutBottomNav = findViewById(R.id.layoutBottomNav)
        viewNavActiveIndicator = findViewById(R.id.viewNavActiveIndicator)
        navTabHome = findViewById(R.id.navTabHome)
        ivNavHome = findViewById(R.id.ivNavHome)
        tvNavHome = findViewById(R.id.tvNavHome)
        navTabSettings = findViewById(R.id.navTabSettings)
        ivNavSettings = findViewById(R.id.ivNavSettings)
        tvNavSettings = findViewById(R.id.tvNavSettings)

        // Tab 1: Home Overview
        heroCard = findViewById(R.id.heroCard)
        tvHeroTitle = findViewById(R.id.tvHeroTitle)
        tvHeroSub = findViewById(R.id.tvHeroSub)
        linkViewHero = findViewById(R.id.linkViewHero)
        layoutHeroCautionBanner = findViewById(R.id.layoutHeroCautionBanner)
        dotHeroCaution = findViewById(R.id.dotHeroCaution)
        tvHeroCautionTitle = findViewById(R.id.tvHeroCautionTitle)
        btnTroubleshootToggle = findViewById(R.id.btnTroubleshootToggle)
        tvHeroCautionText = findViewById(R.id.tvHeroCautionText)
        layoutTroubleshootDetails = findViewById(R.id.layoutTroubleshootDetails)
        tvDevicePhoneName = findViewById(R.id.tvDevicePhoneName)
        tvDeviceMacName = findViewById(R.id.tvDeviceMacName)
        tvLiveBadge = findViewById(R.id.tvLiveBadge)
        btnHeroConnect = findViewById(R.id.btnHeroConnect)

        // Tab 2: Settings
        switchNotifMaster = findViewById(R.id.switchNotifMaster)
        tvNotifMasterPausedNotice = findViewById(R.id.tvNotifMasterPausedNotice)
        layoutNotifSubOptions = findViewById(R.id.layoutNotifSubOptions)
        viewNotifSubAccent = findViewById(R.id.viewNotifSubAccent)
        switchAndroidNotif = findViewById(R.id.switchAndroidNotif)
        switchMacNotif = findViewById(R.id.switchMacNotif)
        rowPhoneVibrate = findViewById(R.id.rowPhoneVibrate)
        switchPhoneVibrate = findViewById(R.id.switchPhoneVibrate)
        rowSettingNotifAccess = findViewById(R.id.rowSettingNotifAccess)
        tvSettingNotifAccessStatus = findViewById(R.id.tvSettingNotifAccessStatus)
        rowSettingAccessibility = findViewById(R.id.rowSettingAccessibility)
        tvSettingAccessibilityStatus = findViewById(R.id.tvSettingAccessibilityStatus)
        tvSettingsDeviceMacName = findViewById(R.id.tvSettingsDeviceMacName)
        tvSettingsDeviceStatus = findViewById(R.id.tvSettingsDeviceStatus)
        btnUnpairMacSettings = findViewById(R.id.btnUnpairMacSettings)

        styleBridgeSwitch(switchNotifMaster)
        styleBridgeSwitch(switchAndroidNotif)
        styleBridgeSwitch(switchMacNotif)
        styleBridgeSwitch(switchPhoneVibrate)

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

    private fun styleBridgeSwitch(sw: SwitchCompat) {
        val states = arrayOf(
            intArrayOf(android.R.attr.state_checked),
            intArrayOf(-android.R.attr.state_checked)
        )
        val thumbColors = intArrayOf(
            colorLime,
            colorMuted
        )
        val trackColors = intArrayOf(
            Color.parseColor("#4D6114"),
            Color.parseColor("#2B2F36")
        )
        sw.thumbTintList = ColorStateList(states, thumbColors)
        sw.trackTintList = ColorStateList(states, trackColors)
    }

    private var navPillAnimator: AnimatorSet? = null

    private fun selectTab(settingsTab: Boolean) {
        if (isSettingsTabSelected == settingsTab) return
        isSettingsTabSelected = settingsTab

        // 1. Update tab icon and label styles
        if (settingsTab) {
            ivNavHome.setImageResource(R.drawable.ic_nav_home_outline)
            ivNavHome.imageTintList = ColorStateList.valueOf(colorSoft)
            tvNavHome.setTextColor(colorSoft)
            tvNavHome.typeface = ivNavSettings.context.resources.getFont(R.font.plus_jakarta_sans_medium)

            ivNavSettings.setImageResource(R.drawable.ic_nav_settings_filled)
            ivNavSettings.imageTintList = ColorStateList.valueOf(colorLime)
            tvNavSettings.setTextColor(colorLime)
            tvNavSettings.typeface = ivNavSettings.context.resources.getFont(R.font.plus_jakarta_sans_semibold)
        } else {
            ivNavHome.setImageResource(R.drawable.ic_nav_home_filled)
            ivNavHome.imageTintList = ColorStateList.valueOf(colorLime)
            tvNavHome.setTextColor(colorLime)
            tvNavHome.typeface = ivNavHome.context.resources.getFont(R.font.plus_jakarta_sans_semibold)

            ivNavSettings.setImageResource(R.drawable.ic_nav_settings_outline)
            ivNavSettings.imageTintList = ColorStateList.valueOf(colorSoft)
            tvNavSettings.setTextColor(colorSoft)
            tvNavSettings.typeface = ivNavSettings.context.resources.getFont(R.font.plus_jakarta_sans_medium)
        }

        // 2. Animate the sliding indicator pill
        navPillAnimator?.cancel()
        val pillWidth = viewNavActiveIndicator.width.toFloat().coerceAtLeast(102f * resources.displayMetrics.density)
        val targetX = if (settingsTab) pillWidth else 0f

        val slideAnim = ObjectAnimator.ofFloat(
            viewNavActiveIndicator,
            "translationX",
            viewNavActiveIndicator.translationX,
            targetX
        ).apply {
            duration = 320
            interpolator = OvershootInterpolator(0.95f)
        }
        val stretchXAnim = ObjectAnimator.ofFloat(
            viewNavActiveIndicator,
            "scaleX",
            1.0f, 1.15f, 0.97f, 1.0f
        ).apply {
            duration = 320
            interpolator = AccelerateDecelerateInterpolator()
        }
        val squashYAnim = ObjectAnimator.ofFloat(
            viewNavActiveIndicator,
            "scaleY",
            1.0f, 0.92f, 1.02f, 1.0f
        ).apply {
            duration = 320
            interpolator = AccelerateDecelerateInterpolator()
        }
        navPillAnimator = AnimatorSet().apply {
            playTogether(slideAnim, stretchXAnim, squashYAnim)
            start()
        }

        // 3. Subtle spring pop on the newly selected tab icon
        val activeIcon = if (settingsTab) ivNavSettings else ivNavHome
        activeIcon.scaleX = 0.82f
        activeIcon.scaleY = 0.82f
        activeIcon.animate()
            .scaleX(1.0f)
            .scaleY(1.0f)
            .setDuration(280)
            .setInterpolator(OvershootInterpolator(1.6f))
            .start()

        updateAccessibilityNotice()
        updateSetupProgress()
        updateSettingsUI()
        updateUI()

        // 4. Smooth cross-fade & slight slide on the newly visible tab page
        val targetPage = if (settingsTab) {
            layoutTabSettings
        } else if (BridgePrefs.isPaired(this)) {
            layoutScreenConnected
        } else {
            layoutScreenPairing
        }
        targetPage.alpha = 0.35f
        targetPage.translationY = 8f * resources.displayMetrics.density
        targetPage.animate()
            .alpha(1.0f)
            .translationY(0f)
            .setDuration(210)
            .setInterpolator(DecelerateInterpolator())
            .start()
    }

    private fun setupListeners() {
        navTabHome.setOnClickListener {
            if (isSettingsTabSelected) {
                selectTab(false)
            }
        }

        navTabSettings.setOnClickListener {
            if (!isSettingsTabSelected) {
                selectTab(true)
            }
        }

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

        rowSettingNotifAccess.setOnClickListener {
            startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
        }

        rowSettingAccessibility.setOnClickListener {
            startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
        }

        btnTroubleshootToggle.setOnClickListener {
            if (layoutTroubleshootDetails.visibility == View.VISIBLE) {
                layoutTroubleshootDetails.visibility = View.GONE
                btnTroubleshootToggle.text = "Details"
            } else {
                layoutTroubleshootDetails.visibility = View.VISIBLE
                btnTroubleshootToggle.text = "Hide"
            }
        }

        switchNotifMaster.setOnCheckedChangeListener { _, isChecked ->
            if (isUpdatingSettingsUi) return@setOnCheckedChangeListener
            BridgePrefs.setNotifMasterEnabled(this, isChecked, updateTimestamp = true)
            if (!isChecked) {
                BridgeNotificationManager.cancelAllMacAlerts(this)
            } else if (BridgePrefs.isAndroidNotifEnabled(this)) {
                BridgeNotificationListenerService.instance?.syncActiveNotifications()
            }
            BridgeNotificationManager.sendSettingsToMac(this)
            updateAccessibilityNotice()
            updateSetupProgress()
            updateSettingsUI()
            updateUI()
        }

        switchAndroidNotif.setOnCheckedChangeListener { _, isChecked ->
            if (isUpdatingSettingsUi) return@setOnCheckedChangeListener
            BridgePrefs.setAndroidNotifEnabled(this, isChecked, updateTimestamp = true)
            if (isChecked && BridgePrefs.isNotifMasterEnabled(this)) {
                BridgeNotificationListenerService.instance?.syncActiveNotifications()
            }
            BridgeNotificationManager.sendSettingsToMac(this)
            updateAccessibilityNotice()
            updateSetupProgress()
            updateSettingsUI()
            updateUI()
        }

        switchMacNotif.setOnCheckedChangeListener { _, isChecked ->
            if (isUpdatingSettingsUi) return@setOnCheckedChangeListener
            BridgePrefs.setMacNotifEnabled(this, isChecked, updateTimestamp = true)
            if (!isChecked) {
                BridgeNotificationManager.cancelAllMacAlerts(this)
            }
            BridgeNotificationManager.sendSettingsToMac(this)
            updateSettingsUI()
            updateUI()
        }

        switchPhoneVibrate.setOnCheckedChangeListener { _, isChecked ->
            if (isUpdatingSettingsUi) return@setOnCheckedChangeListener
            BridgePrefs.setPhoneVibrateEnabled(this, isChecked)
            updateSettingsUI()
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

            userConnectAttempts++
            val localNet = isLocalNetworkAvailable(this)

            var host = etServerIp.text.toString().trim()
            if (host.isEmpty()) {
                host = BridgePrefs.host(this) ?: ""
            }
            val port = etServerPort.text.toString().toIntOrNull() ?: NetworkSyncClient.DEFAULT_PORT

            setConnectingState(true)
            val isCaution = !localNet || userConnectAttempts >= 2 || consecutiveFailures >= 2
            val noteMsg = if (isCaution) {
                "Cannot reach your Mac. Check that your Mac and phone are connected to the same Wi-Fi."
            } else {
                "Looking for your Mac on this Wi-Fi…"
            }
            showPairingNote(noteMsg, if (isCaution) BannerStyle.ERROR else BannerStyle.CONNECTING)

            val hostParam = host.ifEmpty { null }
            ClipboardSyncManager.pair(this, hostParam, port, code)
        }

        btnHeroConnect.setOnClickListener {
            userConnectAttempts++
            if (!isLocalNetworkAvailable(this)) {
                layoutHeroCautionBanner.visibility = View.VISIBLE
                tvHeroCautionTitle.text = "Couldn't connect to your Mac"
                tvHeroCautionText.text = "Bridge couldn't reach your Mac. Please verify the following:"
            }

            setConnectingState(true)
            ClipboardSyncManager.networkClient?.start(
                BridgePrefs.host(this),
                BridgePrefs.port(this),
                BridgePrefs.code(this)
            )
        }

        btnUnpairMacSettings.setOnClickListener {
            showUnpairConfirmationDialog()
        }
    }

    private fun showUnpairConfirmationDialog() {
        AlertDialog.Builder(this)
            .setTitle(R.string.dialog_unpair_title)
            .setMessage(R.string.dialog_unpair_message)
            .setPositiveButton(R.string.dialog_unpair) { _, _ ->
                ClipboardSyncManager.unpair(this)
                etPairCode.setText("")
                consecutiveFailures = 0
                userConnectAttempts = 0
                wasConnectedBefore = false
                layoutNoteBanner.visibility = View.GONE
                setConnectingState(false)
                selectTab(false)
                updateUI()
                Toast.makeText(this, "Unpaired successfully", Toast.LENGTH_SHORT).show()
            }
            .setNegativeButton(R.string.dialog_cancel, null)
            .show()
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
                val code = json.optString("code").replace(" ", "").replace("-", "").trim()
                val rawIp = json.optString("ip").trim()
                val ip = if (rawIp.isNotEmpty() && NetworkSyncClient.isPrivateLocalAddress(rawIp)) rawIp else null
                val rawPort = json.optInt("port", NetworkSyncClient.DEFAULT_PORT)
                val port = if (rawPort in 1024..65535) rawPort else NetworkSyncClient.DEFAULT_PORT

                if (code.length == 6 && code.all { it.isDigit() }) {
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
            tvStatusPill.text = "Connecting..."
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
            btnHeroConnect.isEnabled = true
            btnHeroConnect.text = if (wasConnectedBefore) "Try again" else "Connect to Mac"
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

    private fun updateSetupProgress() {
        if (isSettingsTabSelected || !BridgePrefs.isPaired(this)) {
            layoutSetupProgress.visibility = View.GONE
            return
        }

        var completed = 1 // 1 for Pairing completed
        val total = 3
        val acc = isAccessibilityServiceEnabled()
        val notif = isNotificationServiceEnabled()

        if (acc) completed++
        if (notif) completed++

        if (completed == total) {
            layoutSetupProgress.visibility = View.GONE
        } else {
            val percent = (completed * 100) / total
            tvSetupProgressStatus.text = "$completed of $total completed · $percent%"
            val missing = when {
                !acc && !notif -> "Enable Notification Access and Background Clipboard Service for full sync."
                !acc -> "Enable Background Clipboard Service to keep clipboard synced automatically."
                else -> "Enable Notification Access to mirror notifications to your Mac."
            }
            tvSetupProgressDetail.text = missing
            layoutSetupProgress.visibility = View.VISIBLE
        }
    }

    private fun updateAccessibilityNotice() {
        if (isSettingsTabSelected || isAccessibilityServiceEnabled()) {
            layoutServiceNotice.visibility = View.GONE
        } else {
            layoutServiceNotice.visibility = View.VISIBLE
        }

        if (isSettingsTabSelected || isNotificationServiceEnabled() || !BridgePrefs.isNotificationSyncEnabled(this)) {
            layoutNotificationNotice.visibility = View.GONE
        } else {
            layoutNotificationNotice.visibility = View.VISIBLE
        }
    }

    private fun updateSettingsUI() {
        isUpdatingSettingsUi = true
        try {
            val masterEnabled = BridgePrefs.isNotifMasterEnabled(this)
            val androidEnabled = BridgePrefs.isAndroidNotifEnabled(this)
            val macEnabled = BridgePrefs.isMacNotifEnabled(this)
            val vibrateEnabled = BridgePrefs.isPhoneVibrateEnabled(this)

            switchNotifMaster.isChecked = masterEnabled
            switchAndroidNotif.isChecked = androidEnabled
            switchMacNotif.isChecked = macEnabled
            switchPhoneVibrate.isChecked = vibrateEnabled

            switchAndroidNotif.isEnabled = masterEnabled
            switchMacNotif.isEnabled = masterEnabled
            layoutNotifSubOptions.alpha = if (masterEnabled) 1.0f else 0.42f
            viewNotifSubAccent.setBackgroundColor(
                if (masterEnabled) colorLime else Color.parseColor("#2B2F36")
            )
            tvNotifMasterPausedNotice.visibility = if (masterEnabled) View.GONE else View.VISIBLE

            val macEffective = masterEnabled && macEnabled
            switchPhoneVibrate.isEnabled = macEffective
            rowPhoneVibrate.alpha = if (macEffective) 1.0f else 0.42f

            if (isNotificationServiceEnabled()) {
                tvSettingNotifAccessStatus.text = "Active"
                tvSettingNotifAccessStatus.setTextColor(colorLime)
            } else {
                tvSettingNotifAccessStatus.text = "Required"
                tvSettingNotifAccessStatus.setTextColor(colorCoral)
            }

            if (isAccessibilityServiceEnabled()) {
                tvSettingAccessibilityStatus.text = "Active"
                tvSettingAccessibilityStatus.setTextColor(colorLime)
            } else {
                tvSettingAccessibilityStatus.text = "Required"
                tvSettingAccessibilityStatus.setTextColor(colorCoral)
            }

            val pairedMac = BridgePrefs.macName(this) ?: "Mac"
            tvSettingsDeviceMacName.text = pairedMac
            val isLive = ClipboardSyncManager.networkClient?.isConnected() == true
            tvSettingsDeviceStatus.text = if (isLive) "Connected · Live" else "Paired device · Disconnected"
            tvSettingsDeviceStatus.setTextColor(if (isLive) colorLime else colorMuted)
        } finally {
            isUpdatingSettingsUi = false
        }
    }

    override fun onSettingsChanged() {
        updateAccessibilityNotice()
        updateSetupProgress()
        updateSettingsUI()
        updateUI()
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

    private fun isLocalNetworkAvailable(context: Context): Boolean {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        if (cm != null) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val network = cm.activeNetwork
                if (network != null) {
                    val caps = cm.getNetworkCapabilities(network)
                    if (caps != null && (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                                         caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET))) {
                        return true
                    }
                }
            } else {
                @Suppress("DEPRECATION")
                val info = cm.activeNetworkInfo
                if (info != null && info.isConnected &&
                    (info.type == ConnectivityManager.TYPE_WIFI || info.type == ConnectivityManager.TYPE_ETHERNET)) {
                    return true
                }
            }
        }

        // Check if Hotspot / SoftAP / Tethering or local network interface is UP
        try {
            val interfaces = java.net.NetworkInterface.getNetworkInterfaces() ?: return false
            for (iface in interfaces) {
                if (iface.isUp && !iface.isLoopback) {
                    val name = iface.name.lowercase()
                    val isLocalIface = name.startsWith("wlan") ||
                                       name.startsWith("swlan") ||
                                       name.startsWith("ap") ||
                                       name.startsWith("softap") ||
                                       name.startsWith("rndis") ||
                                       name.startsWith("usb") ||
                                       name.startsWith("p2p") ||
                                       name.startsWith("eth")
                    if (isLocalIface) {
                        for (addr in iface.inetAddresses) {
                            if (!addr.isLoopbackAddress && addr is java.net.Inet4Address) {
                                return true
                            }
                        }
                    }
                }
            }
        } catch (ignored: Exception) {}

        return false
    }

    private fun updateUI() {
        val paired = BridgePrefs.isPaired(this)
        val connected = ClipboardSyncManager.networkClient?.isConnected() == true
        val macName = BridgePrefs.macName(this) ?: "Mac"
        val localNetAvailable = isLocalNetworkAvailable(this)
        val isMultipleFailures = consecutiveFailures >= 2 || userConnectAttempts >= 2

        if (paired) {
            layoutScreenPairing.visibility = View.GONE
            layoutScreenConnected.visibility = if (isSettingsTabSelected) View.GONE else View.VISIBLE
            layoutTabSettings.visibility = if (isSettingsTabSelected) View.VISIBLE else View.GONE
            tvDeviceMacName.text = macName

            updateSettingsUI()
            updateSetupProgress()

            if (connected) {
                wasConnectedBefore = true
                isConnectingState = false
                stopDotBlink()
                consecutiveFailures = 0
                userConnectAttempts = 0

                // Hide troubleshooting banner
                layoutHeroCautionBanner.visibility = View.GONE

                // Header status pill
                tvStatusPill.text = "Connected"
                tvStatusPill.setTextColor(colorLime)
                dotStatus.backgroundTintList = ColorStateList.valueOf(colorLime)

                // Hero card (Lime)
                heroCard.setBackgroundResource(R.drawable.bg_card_lime)
                tvHeroTitle.text = "Your devices are in sync."
                tvHeroTitle.setTextColor(colorInk)
                tvHeroSub.text = "Connected and ready to go."
                tvHeroSub.setTextColor(Color.parseColor("#425010"))
                tvHeroSub.visibility = View.VISIBLE
                linkViewHero.setMode(BridgeLinkView.LinkMode.HERO_CONNECTED)

                // Devices card
                tvLiveBadge.text = "Connected"
                tvLiveBadge.setTextColor(colorLime)

                // Bottom CTAs
                btnHeroConnect.visibility = View.GONE
            } else {
                // Paired but not connected (Idle or Reconnecting)
                val showCaution = !localNetAvailable || isMultipleFailures
                if (showCaution) {
                    layoutHeroCautionBanner.visibility = View.VISIBLE
                    tvHeroCautionTitle.text = "Couldn't connect to your Mac"
                    tvHeroCautionText.text = "Bridge couldn't reach your Mac. Please verify the following:"
                } else {
                    layoutHeroCautionBanner.visibility = View.GONE
                }

                tvLiveBadge.text = if (wasConnectedBefore) "Connection lost" else "Disconnected"
                tvLiveBadge.setTextColor(colorMuted)

                if (isConnectingState) {
                    tvStatusPill.text = "Connecting..."
                    tvStatusPill.setTextColor(colorLime)
                    dotStatus.backgroundTintList = ColorStateList.valueOf(colorLime)
                    startDotBlink()

                    heroCard.setBackgroundResource(R.drawable.bg_card_panel)
                    tvHeroTitle.text = "Connecting..."
                    tvHeroTitle.setTextColor(colorText)
                    tvHeroSub.text = "Looking on your Wi-Fi. This only takes a moment."
                    tvHeroSub.setTextColor(colorMuted)
                    tvHeroSub.visibility = View.VISIBLE
                    linkViewHero.setMode(BridgeLinkView.LinkMode.HERO_CONNECTING)

                    btnHeroConnect.visibility = View.VISIBLE
                    btnHeroConnect.isEnabled = false
                    btnHeroConnect.text = "Connecting…"
                    btnHeroConnect.setTextColor(colorMuted)
                    btnHeroConnect.setBackgroundResource(R.drawable.bg_button_outline)
                } else {
                    stopDotBlink()
                    tvStatusPill.text = if (wasConnectedBefore) "Connection lost" else "Disconnected"
                    tvStatusPill.setTextColor(colorMuted)
                    dotStatus.backgroundTintList = ColorStateList.valueOf(colorMuted)

                    heroCard.setBackgroundResource(R.drawable.bg_card_panel)
                    tvHeroTitle.text = if (wasConnectedBefore) "Connection lost" else "Disconnected"
                    tvHeroTitle.setTextColor(colorText)
                    tvHeroSub.text = if (wasConnectedBefore) {
                        "Your Mac dropped offline or moved to another network."
                    } else {
                        "Your Mac is paired. Tap below to reconnect."
                    }
                    tvHeroSub.setTextColor(colorMuted)
                    tvHeroSub.visibility = View.VISIBLE
                    linkViewHero.setMode(BridgeLinkView.LinkMode.HERO_IDLE)

                    btnHeroConnect.visibility = View.VISIBLE
                    btnHeroConnect.isEnabled = true
                    btnHeroConnect.text = if (wasConnectedBefore) "Try again" else "Connect to Mac"
                    btnHeroConnect.setTextColor(colorInk)
                    btnHeroConnect.setBackgroundResource(R.drawable.bg_button_lime)
                }
            }
        } else {
            // Not Paired (Screen B)
            layoutScreenConnected.visibility = View.GONE
            layoutScreenPairing.visibility = if (isSettingsTabSelected) View.GONE else View.VISIBLE
            layoutTabSettings.visibility = if (isSettingsTabSelected) View.VISIBLE else View.GONE
            layoutSetupProgress.visibility = View.GONE

            if (isConnectingState) {
                tvStatusPill.text = "Connecting..."
                tvStatusPill.setTextColor(colorLime)
                dotStatus.backgroundTintList = ColorStateList.valueOf(colorLime)
                startDotBlink()

                linkViewPairing.setMode(BridgeLinkView.LinkMode.PAIRING_CONNECTING)
                btnPair.isEnabled = false
                btnPair.text = "Connecting…"
            } else {
                stopDotBlink()
                tvStatusPill.text = "Disconnected"
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
            if (isConnected) {
                consecutiveFailures = 0
                userConnectAttempts = 0
                wasConnectedBefore = true
            }
            updateUI()
        }
    }

    override fun onConnectionFailed(consecutiveFailures: Int) {
        runOnUiThread {
            this.consecutiveFailures = consecutiveFailures
            if (ClipboardSyncManager.networkClient?.isConnected() != true) {
                isConnectingState = false
                if (!BridgePrefs.isPaired(this)) {
                    val noteMsg = if (consecutiveFailures >= 2 || userConnectAttempts >= 2) {
                        "Cannot reach your Mac. Check that your Mac and phone are connected to the same Wi-Fi."
                    } else {
                        "Couldn't reach your Mac. Check that you're on the same Wi-Fi and Bridge is open."
                    }
                    showPairingNote(noteMsg, BannerStyle.ERROR)
                }
                updateUI()
            }
        }
    }

    override fun onPairingResult(accepted: Boolean, macName: String?) {
        runOnUiThread {
            isConnectingState = false
            if (accepted) {
                consecutiveFailures = 0
                userConnectAttempts = 0
                wasConnectedBefore = true
                showPairingNote("Connected. You're all set.", BannerStyle.CONNECTED)
                updateUI()
            } else {
                consecutiveFailures++
                val msg = if (consecutiveFailures >= 2 || userConnectAttempts >= 2) {
                    "Cannot reach your Mac. Check that your Mac and phone are connected to the same Wi-Fi."
                } else {
                    "Couldn't reach your Mac. Check that you're on the same Wi-Fi and Bridge is open on it."
                }
                showPairingNote(msg, BannerStyle.ERROR)
                updateUI()
            }
        }
    }

    override fun onRemoteUnpair() {
        runOnUiThread {
            isConnectingState = false
            etPairCode.setText("")
            consecutiveFailures = 0
            userConnectAttempts = 0
            wasConnectedBefore = false
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
                    val noteMsg = if (consecutiveFailures >= 2 || userConnectAttempts >= 2) {
                        "Cannot reach your Mac. Check that your Mac and phone are connected to the same Wi-Fi."
                    } else {
                        "Couldn't reach your Mac. Check that you're on the same Wi-Fi and Bridge is open."
                    }
                    showPairingNote(noteMsg, BannerStyle.ERROR)
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
