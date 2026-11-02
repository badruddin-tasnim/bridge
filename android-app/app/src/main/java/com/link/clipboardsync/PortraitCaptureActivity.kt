package com.link.clipboardsync

import com.journeyapps.barcodescanner.CaptureActivity

/**
 * Custom CaptureActivity locked to portrait orientation to prevent
 * camera rotation when scanning QR codes on Android devices.
 */
class PortraitCaptureActivity : CaptureActivity()
