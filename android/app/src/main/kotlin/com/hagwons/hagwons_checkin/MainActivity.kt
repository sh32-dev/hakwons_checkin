package com.hagwons.hagwons_checkin

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.acs.smartcard.Reader as AcsReader
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.nio.charset.Charset
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean

private const val LOG_TAG = "Acr122uReader"

class MainActivity : FlutterActivity() {
    private lateinit var usbManager: UsbManager
    private var eventSink: EventChannel.EventSink? = null
    private var reader: Acr122uReader? = null
    private var receiverRegistered = false
    private val mainHandler = Handler(Looper.getMainLooper())
    private var retryReaderRunnable: Runnable? = null

    private val usbReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                ACTION_USB_PERMISSION -> {
                    val device = intent.usbDevice() ?: return
                    if (!device.isAcr122u()) return
                    if (intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)) {
                        openReader(device)
                    } else {
                        emitError("USB 리더기 권한이 거부되었습니다.")
                    }
                }

                UsbManager.ACTION_USB_DEVICE_ATTACHED -> {
                    val device = intent.usbDevice() ?: return
                    if (device.isAcr122u()) startReader()
                }

                UsbManager.ACTION_USB_DEVICE_DETACHED -> {
                    val device = intent.usbDevice() ?: return
                    if (device.isAcr122u()) {
                        closeReader()
                        emitError("USB 리더기가 분리되었습니다.")
                    }
                }
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        usbManager = getSystemService(Context.USB_SERVICE) as UsbManager
        registerUsbReceiver()

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        startReader()
                        result.success(null)
                    }

                    "stop" -> {
                        cancelReaderRetry()
                        closeReader()
                        result.success(null)
                    }

                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(
                object : EventChannel.StreamHandler {
                    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                        eventSink = events
                    }

                    override fun onCancel(arguments: Any?) {
                        eventSink = null
                    }
                },
            )
    }

    override fun onDestroy() {
        cancelReaderRetry()
        closeReader()
        if (receiverRegistered) {
            unregisterReceiver(usbReceiver)
            receiverRegistered = false
        }
        super.onDestroy()
    }

    private fun registerUsbReceiver() {
        if (receiverRegistered) return
        val filter =
            IntentFilter().apply {
                addAction(ACTION_USB_PERMISSION)
                addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
                addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
            }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(usbReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            registerReceiver(usbReceiver, filter)
        }
        receiverRegistered = true
    }

    private fun startReader() {
        val devices = usbManager.deviceList.values.toList()
        Log.i(LOG_TAG, "startReader deviceCount=${devices.size} devices=${devices.describe()}")
        val device = usbManager.deviceList.values.firstOrNull { it.isAcr122u() }
        if (device == null) {
            Log.i(LOG_TAG, "ACR122U not found; retrying")
            emitStatus("ACR122U USB 리더기 연결을 기다리는 중입니다.")
            scheduleReaderRetry()
            return
        }

        cancelReaderRetry()
        if (!usbManager.hasPermission(device)) {
            Log.i(LOG_TAG, "request USB permission for ACR122U")
            emitStatus("USB 리더기 권한을 허용해주세요.")
            usbManager.requestPermission(device, permissionIntent())
            return
        }

        Log.i(LOG_TAG, "ACR122U permission already granted")
        openReader(device)
    }

    private fun scheduleReaderRetry() {
        if (retryReaderRunnable != null) return
        val runnable =
            object : Runnable {
                override fun run() {
                    retryReaderRunnable = null
                    if (reader == null) startReader()
                }
            }
        retryReaderRunnable = runnable
        mainHandler.postDelayed(runnable, USB_RETRY_DELAY_MS)
    }

    private fun cancelReaderRetry() {
        retryReaderRunnable?.let { mainHandler.removeCallbacks(it) }
        retryReaderRunnable = null
    }

    private fun permissionIntent(): PendingIntent {
        val flags =
            PendingIntent.FLAG_UPDATE_CURRENT or
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    PendingIntent.FLAG_MUTABLE
                } else {
                    0
                }
        return PendingIntent.getBroadcast(
            this,
            0,
            Intent(ACTION_USB_PERMISSION).setPackage(packageName),
            flags,
        )
    }

    private fun openReader(device: UsbDevice) {
        closeReader()
        try {
            Log.i(LOG_TAG, "open ACR122U reader")
            val nextReader =
                Acr122uReader(
                    usbManager = usbManager,
                    device = device,
                    onStatus = ::emitStatus,
                    onUid = ::emitUid,
                    onError = ::emitError,
                )
            nextReader.start()
            reader = nextReader
        } catch (error: Exception) {
            Log.e(LOG_TAG, "failed to open reader", error)
            emitError(error.message ?: "USB 리더기를 열지 못했습니다.")
        }
    }

    private fun closeReader() {
        reader?.close()
        reader = null
    }

    private fun emitUid(uid: String) {
        runOnUiThread {
            eventSink?.success(
                mapOf(
                    "type" to "uid",
                    "uid" to uid.replace(Regex("[\\s:-]"), "").uppercase(Locale.US),
                ),
            )
        }
    }

    private fun emitStatus(message: String) {
        runOnUiThread {
            eventSink?.success(
                mapOf(
                    "type" to "status",
                    "message" to message,
                ),
            )
        }
    }

    private fun emitError(message: String) {
        runOnUiThread {
            eventSink?.success(
                mapOf(
                    "type" to "error",
                    "message" to message,
                ),
            )
        }
    }

    private fun Intent.usbDevice(): UsbDevice? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
        } else {
            @Suppress("DEPRECATION")
            getParcelableExtra(UsbManager.EXTRA_DEVICE)
        }
    }

    private fun UsbDevice.isAcr122u(): Boolean {
        return vendorId == ACR122U_VENDOR_ID && productId == ACR122U_PRODUCT_ID
    }

    private fun List<UsbDevice>.describe(): String {
        if (isEmpty()) return "[]"
        return joinToString(prefix = "[", postfix = "]") {
            "vid=${it.vendorId.toString(16)} pid=${it.productId.toString(16)} name=${it.deviceName}"
        }
    }

    companion object {
        private const val METHOD_CHANNEL = "hakwons_checkin/acr122u"
        private const val EVENT_CHANNEL = "hakwons_checkin/acr122u_events"
        private const val ACTION_USB_PERMISSION = "com.hagwons.hagwons_checkin.USB_PERMISSION"
        private const val ACR122U_VENDOR_ID = 0x072F
        private const val ACR122U_PRODUCT_ID = 0x2200
        private const val USB_RETRY_DELAY_MS = 1_500L
    }
}

private class Acr122uReader(
    private val usbManager: UsbManager,
    private val device: UsbDevice,
    private val onStatus: (String) -> Unit,
    private val onUid: (String) -> Unit,
    private val onError: (String) -> Unit,
) {
    private val sdkReader = AcsReader(usbManager)
    private val running = AtomicBoolean(false)
    private val cardSignal = Object()
    private val readRequested = AtomicBoolean(false)
    private var worker: Thread? = null

    fun start() {
        if (!sdkReader.isSupported(device)) {
            throw IllegalStateException("ACS SDK가 이 USB 리더기를 지원하지 않습니다.")
        }

        sdkReader.setOnStateChangeListener { slotNum, prevState, currState ->
            Log.d(
                LOG_TAG,
                "ACS state slot=$slotNum ${stateName(prevState)} -> ${stateName(currState)}",
            )
            if (slotNum == SLOT_NUM && currState.isReadableCardState()) {
                readRequested.set(true)
                synchronized(cardSignal) {
                    cardSignal.notifyAll()
                }
            }
        }
        sdkReader.open(device)
        Log.i(
            LOG_TAG,
            "ACS reader opened name=${sdkReader.readerName} slots=${sdkReader.numSlots}",
        )
        if (sdkReader.numSlots <= SLOT_NUM) {
            sdkReader.close()
            throw IllegalStateException("ACR122U 카드 슬롯을 찾지 못했습니다.")
        }

        running.set(true)
        onStatus("USB 리더기 연결됨. 카드를 태그해주세요.")
        worker =
            Thread({ pollCards() }, "acr122u-acs-poll").apply {
                isDaemon = true
                start()
            }
    }

    fun close() {
        running.set(false)
        worker?.interrupt()
        worker = null
        runCatching { sdkReader.close() }
    }

    private fun pollCards() {
        var lastCardId: String? = null
        var lastEmitAt = 0L
        Log.i(LOG_TAG, "ACS poll thread started")

        while (running.get()) {
            try {
                waitForCard()
                val cardId = readNdefTextCardId()
                val now = System.currentTimeMillis()
                if (cardId != lastCardId || now - lastEmitAt >= SAME_CARD_RETAG_INTERVAL_MS) {
                    lastCardId = cardId
                    lastEmitAt = now
                    Log.d(LOG_TAG, "emit cardId=$cardId")
                    onUid(cardId)
                }
                Thread.sleep(POLL_INTERVAL_MS)
            } catch (interrupted: InterruptedException) {
                Thread.currentThread().interrupt()
                return
            } catch (_: CardAbsentException) {
                lastCardId = null
                lastEmitAt = 0L
            } catch (error: NdefTextNotFoundException) {
                Log.d(LOG_TAG, "NDEF text not found after reading tag memory")
                if (lastCardId != NDEF_ERROR_SENTINEL) {
                    lastCardId = NDEF_ERROR_SENTINEL
                    lastEmitAt = System.currentTimeMillis()
                    onError("NDEF Text를 읽지 못했습니다. 출결 ID가 저장된 스티커인지 확인해주세요.")
                }
                sleepQuietly()
            } catch (error: Exception) {
                Log.e(LOG_TAG, "ACS reader poll failed ${error.diagnosticMessage()}", error)
                onError(error.message ?: "USB 리더기 통신 오류가 발생했습니다.")
                sleepQuietly()
            }
        }
    }

    private fun waitForCard() {
        if (readRequested.getAndSet(false)) return
        if (sdkReader.getState(SLOT_NUM).isReadableCardState()) return
        synchronized(cardSignal) {
            if (!running.get()) return
            cardSignal.wait(POLL_INTERVAL_MS)
        }
        readRequested.getAndSet(false)
    }

    private fun sleepQuietly() {
        try {
            Thread.sleep(POLL_INTERVAL_MS)
        } catch (interrupted: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }

    private fun readNdefTextCardId(): String {
        prepareCard()
        val uid = readUid() ?: throw CardAbsentException()
        Log.d(LOG_TAG, "card present uid=$uid")
        val ndefMessage = readType2NdefMessage()
        Log.d(LOG_TAG, "ndef message=${ndefMessage.hexPreview(48)}")
        val text = firstNdefTextRecord(ndefMessage) ?: throw NdefTextNotFoundException()
        Log.d(LOG_TAG, "ndef text=$text")
        return text.replace(Regex("[\\s:-]"), "").uppercase(Locale.US)
    }

    private fun prepareCard() {
        val state = sdkReader.getState(SLOT_NUM)
        Log.d(LOG_TAG, "ACS card state=${stateName(state)}")
        if (state == AcsReader.CARD_ABSENT || state == AcsReader.CARD_UNKNOWN) {
            throw CardAbsentException()
        }

        runCatching {
            val atr = sdkReader.power(SLOT_NUM, AcsReader.CARD_WARM_RESET)
            Log.d(LOG_TAG, "ACS warm reset ATR=${atr?.hexPreview(48) ?: "none"}")
        }.onFailure {
            if (it.isCardGone()) throw CardAbsentException(it.diagnosticMessage())
            Log.d(LOG_TAG, "ACS warm reset skipped ${it.diagnosticMessage()}")
        }

        runCatching {
            val protocol = sdkReader.setProtocol(
                SLOT_NUM,
                AcsReader.PROTOCOL_T0 or AcsReader.PROTOCOL_T1,
            )
            Log.d(LOG_TAG, "ACS active protocol=$protocol")
        }.onFailure {
            if (it.isCardGone()) throw CardAbsentException(it.diagnosticMessage())
            Log.d(LOG_TAG, "ACS set protocol skipped ${it.diagnosticMessage()}")
        }
    }

    private fun readType2NdefMessage(): ByteArray {
        var lastError: Throwable? = null
        repeat(TYPE2_NDEF_READ_ATTEMPTS) { attempt ->
            val ndef =
                runCatching {
                    readType2NdefMessageOnce()
                }.onFailure {
                    lastError = it
                    Log.d(
                        LOG_TAG,
                        "type2 NDEF read attempt=${attempt + 1} failed ${it.diagnosticMessage()}",
                    )
                    sleepBetweenType2Retries(TYPE2_NDEF_READ_RETRY_DELAY_MS)
                }.getOrNull()
            if (ndef != null) return ndef
        }
        throw CardAbsentException("type2 NDEF read failed after retries: ${lastError?.diagnosticMessage()}")
    }

    private fun readType2NdefMessageOnce(): ByteArray {
        val memory = mutableListOf<Byte>()
        for (page in TYPE2_NDEF_START_PAGE..TYPE2_MAX_READ_PAGE) {
            val pageData = readType2Page(page)
            Log.d(LOG_TAG, "type2 page$page=${pageData.hexPreview(16)}")
            memory += pageData.toList()
            val ndef = extractNdefTlv(memory.toByteArray())
            if (ndef != null) return ndef
        }
        throw NdefTextNotFoundException()
    }

    private fun readType2Page(page: Int): ByteArray {
        repeat(TYPE2_PAGE_READ_ATTEMPTS) { attempt ->
            val shortRead =
                runCatching {
                    readBinary(page, TYPE2_PAGE_LENGTH)
                }.onFailure {
                    Log.d(
                        LOG_TAG,
                        "type2 page read failed page=$page attempt=${attempt + 1} ${it.diagnosticMessage()}",
                    )
                    sleepBetweenType2Retries(TYPE2_PAGE_READ_RETRY_DELAY_MS)
                }.getOrNull()
            if (shortRead != null) return shortRead
        }
        throw CardAbsentException("type2 page read failed page=$page")
    }

    private fun sleepBetweenType2Retries(delayMs: Long) {
        try {
            Thread.sleep(delayMs)
        } catch (interrupted: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }

    private fun readBinary(block: Int, length: Int): ByteArray {
        val apdu =
            byteArrayOf(
                0xFF.toByte(),
                0xB0.toByte(),
                0x00,
                (block and 0xFF).toByte(),
                (length and 0xFF).toByte(),
            )
        Log.d(LOG_TAG, "APDU readBinary block=$block length=$length tx=${apdu.hexPreview(16)}")
        val response = transmitApdu(apdu)
        Log.d(LOG_TAG, "APDU readBinary block=$block length=$length rx=${response.hexPreview(32)}")
        return successfulData(response)
    }

    private fun extractNdefTlv(memory: ByteArray): ByteArray? {
        var index = 0
        while (index < memory.size) {
            val type = memory[index].toInt() and 0xFF
            index += 1
            when (type) {
                0x00 -> continue
                0xFE -> return null
                0x03 -> {
                    if (index >= memory.size) return null
                    var length = memory[index].toInt() and 0xFF
                    index += 1
                    if (length == 0xFF) {
                        if (index + 1 >= memory.size) return null
                        length =
                            ((memory[index].toInt() and 0xFF) shl 8) or
                                (memory[index + 1].toInt() and 0xFF)
                        index += 2
                    }
                    if (index + length > memory.size) return null
                    return memory.copyOfRange(index, index + length)
                }
                else -> {
                    if (index >= memory.size) return null
                    var length = memory[index].toInt() and 0xFF
                    index += 1
                    if (length == 0xFF) {
                        if (index + 1 >= memory.size) return null
                        length =
                            ((memory[index].toInt() and 0xFF) shl 8) or
                                (memory[index + 1].toInt() and 0xFF)
                        index += 2
                    }
                    index += length
                }
            }
        }
        return null
    }

    private fun firstNdefTextRecord(message: ByteArray): String? {
        var index = 0
        while (index < message.size) {
            val header = message[index].toInt() and 0xFF
            index += 1
            val shortRecord = (header and 0x10) != 0
            val hasId = (header and 0x08) != 0
            val tnf = header and 0x07

            if (index >= message.size) return null
            val typeLength = message[index].toInt() and 0xFF
            index += 1

            val payloadLength: Int
            if (shortRecord) {
                if (index >= message.size) return null
                payloadLength = message[index].toInt() and 0xFF
                index += 1
            } else {
                if (index + 3 >= message.size) return null
                payloadLength =
                    ((message[index].toInt() and 0xFF) shl 24) or
                        ((message[index + 1].toInt() and 0xFF) shl 16) or
                        ((message[index + 2].toInt() and 0xFF) shl 8) or
                        (message[index + 3].toInt() and 0xFF)
                index += 4
            }

            val idLength =
                if (hasId) {
                    if (index >= message.size) return null
                    (message[index].toInt() and 0xFF).also { index += 1 }
                } else {
                    0
                }

            if (index + typeLength + idLength + payloadLength > message.size) return null
            val type = message.copyOfRange(index, index + typeLength)
            index += typeLength + idLength
            val payload = message.copyOfRange(index, index + payloadLength)
            index += payloadLength

            val isWellKnownText =
                tnf == 0x01 &&
                    type.size == 1 &&
                    type[0].toInt().toChar() == 'T'
            if (isWellKnownText) {
                Log.d(
                    LOG_TAG,
                    "NDEF text record header=${"%02X".format(header)} tnf=$tnf payloadLength=$payloadLength",
                )
                return decodeNdefTextPayload(payload)
            }
        }
        return null
    }

    private fun decodeNdefTextPayload(payload: ByteArray): String? {
        if (payload.isEmpty()) return null
        val status = payload[0].toInt() and 0xFF
        val languageLength = status and 0x3F
        val textOffset = 1 + languageLength
        if (payload.size <= textOffset) return null

        val charset: Charset =
            if ((status and 0x80) != 0) {
                UTF_16_CHARSET
            } else {
                Charsets.UTF_8
            }
        return payload.copyOfRange(textOffset, payload.size).toString(charset).trim()
    }

    private fun readUid(): String? {
        val apdu = byteArrayOf(0xFF.toByte(), 0xCA.toByte(), 0x00, 0x00, 0x00)
        Log.d(LOG_TAG, "APDU readUid tx=${apdu.hexPreview(16)}")
        val response = transmitApdu(apdu)
        Log.d(LOG_TAG, "APDU readUid rx=${response.hexPreview(32)}")
        if (response.size < 2) return null

        val uidBytes =
            runCatching {
                successfulData(response)
            }.onFailure {
                Log.d(LOG_TAG, "APDU readUid parse failed ${it.diagnosticMessage()}")
            }.getOrNull() ?: return null
        if (uidBytes.isEmpty()) return null
        return uidBytes.joinToString("") { "%02X".format(it.toInt() and 0xFF) }
    }

    private fun successfulData(response: ByteArray): ByteArray {
        if (response.size < 2) {
            throw ApduStatusException("APDU response too short response=${response.hexPreview(32)}")
        }
        val sw1 = response[response.lastIndex - 1].toInt() and 0xFF
        val sw2 = response[response.lastIndex].toInt() and 0xFF
        if (sw1 != 0x90 || sw2 != 0x00) {
            throw ApduStatusException(
                "APDU SW=${"%02X".format(sw1)} ${"%02X".format(sw2)} response=${response.hexPreview(32)}",
            )
        }
        return response.copyOfRange(0, response.size - 2)
    }

    private fun transmitApdu(apdu: ByteArray): ByteArray {
        val response = ByteArray(APDU_RESPONSE_BUFFER_SIZE)
        val responseLength =
            try {
                sdkReader.transmit(SLOT_NUM, apdu, apdu.size, response, response.size)
            } catch (error: Throwable) {
                if (error.isCardGone()) throw CardAbsentException(error.diagnosticMessage())
                throw error
            }
        if (responseLength <= 0 || responseLength > response.size) {
            throw ApduStatusException("APDU invalid response length=$responseLength")
        }
        return response.copyOf(responseLength)
    }

    private fun Throwable.isCardGone(): Boolean {
        val name = this::class.java.simpleName
        return name == "RemovedCardException" ||
            name == "UnpoweredCardException" ||
            name == "UnresponsiveCardException" ||
            name == "UnsupportedCardException"
    }

    private fun stateName(state: Int): String {
        return when (state) {
            AcsReader.CARD_UNKNOWN -> "Unknown"
            AcsReader.CARD_ABSENT -> "Absent"
            AcsReader.CARD_PRESENT -> "Present"
            AcsReader.CARD_SWALLOWED -> "Swallowed"
            AcsReader.CARD_POWERED -> "Powered"
            AcsReader.CARD_NEGOTIABLE -> "Negotiable"
            AcsReader.CARD_SPECIFIC -> "Specific"
            else -> "Unknown($state)"
        }
    }

    private fun Int.isReadableCardState(): Boolean {
        return this == AcsReader.CARD_PRESENT ||
            this == AcsReader.CARD_POWERED ||
            this == AcsReader.CARD_NEGOTIABLE ||
            this == AcsReader.CARD_SPECIFIC
    }

    companion object {
        private const val SLOT_NUM = 0
        private const val APDU_RESPONSE_BUFFER_SIZE = 300
        private const val POLL_INTERVAL_MS = 150L
        private const val SAME_CARD_RETAG_INTERVAL_MS = 2_500L
        private const val TYPE2_NDEF_START_PAGE = 4
        private const val TYPE2_MAX_READ_PAGE = 64
        private const val TYPE2_PAGE_LENGTH = 4
        private const val TYPE2_NDEF_READ_ATTEMPTS = 2
        private const val TYPE2_PAGE_READ_ATTEMPTS = 2
        private const val TYPE2_PAGE_READ_RETRY_DELAY_MS = 80L
        private const val TYPE2_NDEF_READ_RETRY_DELAY_MS = 180L
        private const val NDEF_ERROR_SENTINEL = "__NDEF_TEXT_NOT_FOUND__"
        private val UTF_16_CHARSET: Charset = Charset.forName("UTF-16")
    }
}

private class CardAbsentException(message: String? = null) : Exception(message)
private class NdefTextNotFoundException : Exception()
private class ApduStatusException(message: String) : Exception(message)

private fun Throwable.diagnosticMessage(): String {
    return "${this::class.java.simpleName}: ${message ?: "(no message)"}"
}

private fun ByteArray.hexPreview(limit: Int): String {
    return take(limit).joinToString(" ") { "%02X".format(it.toInt() and 0xFF) }
}
