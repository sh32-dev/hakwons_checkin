package com.hagwons.hagwons_checkin

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.nio.charset.Charset
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max

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

private data class CcidEndpoints(
    val usbInterface: UsbInterface,
    val bulkIn: UsbEndpoint,
    val bulkOut: UsbEndpoint,
)

private data class CcidResponse(
    val messageType: Int,
    val status: Int,
    val error: Int,
    val payload: ByteArray,
)

private enum class CardPresence { Absent, Present }

private class Acr122uReader(
    private val usbManager: UsbManager,
    private val device: UsbDevice,
    private val onStatus: (String) -> Unit,
    private val onUid: (String) -> Unit,
    private val onError: (String) -> Unit,
) {
    private val running = AtomicBoolean(false)
    private var connection: UsbDeviceConnection? = null
    private var claimedInterface: UsbInterface? = null
    private var bulkIn: UsbEndpoint? = null
    private var bulkOut: UsbEndpoint? = null
    private var worker: Thread? = null
    private var sequence = 0

    fun start() {
        val endpoints = findCcidEndpoints()
            ?: throw IllegalStateException("ACR122U CCID bulk endpoint를 찾지 못했습니다.")
        val nextConnection =
            usbManager.openDevice(device)
                ?: throw IllegalStateException("USB 리더기 연결을 열지 못했습니다.")

        if (!nextConnection.claimInterface(endpoints.usbInterface, true)) {
            nextConnection.close()
            throw IllegalStateException("ACR122U USB 인터페이스를 사용할 수 없습니다.")
        }

        connection = nextConnection
        claimedInterface = endpoints.usbInterface
        bulkIn = endpoints.bulkIn
        bulkOut = endpoints.bulkOut
        running.set(true)
        flushPendingBulkResponses("startup")
        Log.i(
            LOG_TAG,
            "CCID reader opened endpoints=interface=${endpoints.usbInterface.id} " +
                "in=${endpoints.bulkIn.address} out=${endpoints.bulkOut.address}",
        )
        onStatus("USB 리더기 연결됨. 카드를 태그해주세요.")
        worker =
            Thread({ pollCards() }, "acr122u-ccid-poll").apply {
                isDaemon = true
                start()
            }
    }

    fun close() {
        running.set(false)
        worker?.interrupt()
        worker = null
        val activeConnection = connection
        val activeInterface = claimedInterface
        if (activeConnection != null && activeInterface != null) {
            runCatching { activeConnection.releaseInterface(activeInterface) }
        }
        runCatching { activeConnection?.close() }
        connection = null
        claimedInterface = null
        bulkIn = null
        bulkOut = null
    }

    private fun pollCards() {
        var lastPresence = CardPresence.Absent
        var currentCardHandled = false
        var ndefErrorShown = false
        var lastCommunicationErrorAt = 0L
        Log.i(LOG_TAG, "CCID poll thread started")

        while (running.get()) {
            try {
                val presence = readCardPresence()
                if (presence != lastPresence) {
                    Log.d(LOG_TAG, "CCID state $lastPresence -> $presence")
                    lastPresence = presence
                }

                if (presence == CardPresence.Absent) {
                    currentCardHandled = false
                    ndefErrorShown = false
                    sleepPollingInterval()
                    continue
                }

                if (!currentCardHandled) {
                    Thread.sleep(CARD_SETTLE_DELAY_MS)
                    if (readCardPresence() == CardPresence.Absent) {
                        currentCardHandled = false
                        ndefErrorShown = false
                        lastPresence = CardPresence.Absent
                        sleepPollingInterval()
                        continue
                    }

                    try {
                        val cardId = readNdefTextCardIdWithRetries()
                        Log.d(LOG_TAG, "emit cardId=$cardId")
                        onUid(cardId)
                    } catch (_: NdefTextNotFoundException) {
                        if (!ndefErrorShown) {
                            onError("NDEF Text를 읽지 못했습니다. 출결 ID가 저장된 스티커인지 확인해주세요.")
                            ndefErrorShown = true
                        }
                    }
                    currentCardHandled = true
                }

                sleepPollingInterval()
            } catch (interrupted: InterruptedException) {
                Thread.currentThread().interrupt()
                return
            } catch (_: CardAbsentException) {
                currentCardHandled = false
                ndefErrorShown = false
                lastPresence = CardPresence.Absent
            } catch (timeout: CcidResponseTimeoutException) {
                Log.d(LOG_TAG, "CCID reader poll timeout ${timeout.diagnosticMessage()}")
                flushPendingBulkResponses("poll-timeout")
                sleepAfterError()
            } catch (error: Exception) {
                Log.e(LOG_TAG, "CCID reader poll failed ${error.diagnosticMessage()}", error)
                val now = System.currentTimeMillis()
                if (now - lastCommunicationErrorAt >= COMMUNICATION_ERROR_INTERVAL_MS) {
                    lastCommunicationErrorAt = now
                    onError("USB 리더기 통신 오류가 발생했습니다. 리더기를 다시 연결해주세요.")
                }
                sleepAfterError()
            }
        }
    }

    private fun readNdefTextCardIdWithRetries(): String {
        var lastError: Throwable? = null
        repeat(CARD_READ_ATTEMPTS) { attempt ->
            try {
                powerOnCard()
                val ndefMessage = readType2NdefMessage()
                Log.d(LOG_TAG, "ndef message=${ndefMessage.hexPreview(48)}")
                val text = firstNdefTextRecord(ndefMessage) ?: throw NdefTextNotFoundException()
                Log.d(LOG_TAG, "ndef text=$text")
                return text.replace(Regex("[\\s:-]"), "").uppercase(Locale.US)
            } catch (error: NdefTextNotFoundException) {
                throw error
            } catch (error: CardAbsentException) {
                if (readCardPresence() == CardPresence.Absent) throw error
                lastError = error
                Log.d(
                    LOG_TAG,
                    "NDEF read attempt=${attempt + 1} stopped while present ${error.diagnosticMessage()}",
                )
            } catch (error: Exception) {
                lastError = error
                Log.d(
                    LOG_TAG,
                    "NDEF read attempt=${attempt + 1} failed ${error.diagnosticMessage()}",
                )
            }

            if (attempt < CARD_READ_ATTEMPTS - 1) {
                Thread.sleep(CARD_READ_RETRY_DELAY_MS)
            }
        }
        throw NdefTextNotFoundException("NDEF read failed after retries: ${lastError?.diagnosticMessage()}")
    }

    private fun findCcidEndpoints(): CcidEndpoints? {
        for (interfaceIndex in 0 until device.interfaceCount) {
            val usbInterface = device.getInterface(interfaceIndex)
            var bulkInEndpoint: UsbEndpoint? = null
            var bulkOutEndpoint: UsbEndpoint? = null
            for (endpointIndex in 0 until usbInterface.endpointCount) {
                val endpoint = usbInterface.getEndpoint(endpointIndex)
                if (endpoint.type != UsbConstants.USB_ENDPOINT_XFER_BULK) continue
                when (endpoint.direction) {
                    UsbConstants.USB_DIR_IN -> bulkInEndpoint = endpoint
                    UsbConstants.USB_DIR_OUT -> bulkOutEndpoint = endpoint
                }
            }
            val inEndpoint = bulkInEndpoint
            val outEndpoint = bulkOutEndpoint
            if (inEndpoint != null && outEndpoint != null) {
                return CcidEndpoints(usbInterface, inEndpoint, outEndpoint)
            }
        }
        return null
    }

    private fun readCardPresence(): CardPresence {
        val response =
            sendCcidCommand(
                commandType = PC_TO_RDR_GET_SLOT_STATUS,
                expectedResponseType = RDR_TO_PC_SLOT_STATUS,
                payload = ByteArray(0),
                name = "GetSlotStatus",
            )
        return if ((response.status and CCID_SLOT_STATUS_MASK) == CCID_SLOT_STATUS_ABSENT) {
            CardPresence.Absent
        } else {
            CardPresence.Present
        }
    }

    private fun powerOnCard() {
        val response =
            sendCcidCommand(
                commandType = PC_TO_RDR_ICC_POWER_ON,
                expectedResponseType = RDR_TO_PC_DATA_BLOCK,
                payload = ByteArray(0),
                params = byteArrayOf(0x00, 0x00, 0x00),
                name = "IccPowerOn",
            )
        Log.d(LOG_TAG, "CCID power on ATR=${response.payload.hexPreview(48)}")
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
        throw lastError ?: NdefTextNotFoundException()
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
        throw ApduStatusException("type2 page read failed page=$page")
    }

    private fun sleepBetweenType2Retries(delayMs: Long) {
        Thread.sleep(delayMs)
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

    private fun transmitApdu(apdu: ByteArray): ByteArray {
        val response =
            sendCcidCommand(
                commandType = PC_TO_RDR_XFR_BLOCK,
                expectedResponseType = RDR_TO_PC_DATA_BLOCK,
                payload = apdu,
                params = byteArrayOf(0x00, 0x00, 0x00),
                name = "XfrBlock",
            )
        return response.payload
    }

    private fun sendCcidCommand(
        commandType: Int,
        expectedResponseType: Int,
        payload: ByteArray,
        params: ByteArray = byteArrayOf(0x00, 0x00, 0x00),
        name: String,
    ): CcidResponse {
        val commandSequence = sequence
        sequence = (sequence + 1) and 0xFF
        val command = ccidCommand(commandType, commandSequence, payload, params)
        writeBulk(command)
        return readCcidResponse(commandSequence, expectedResponseType, name)
    }

    private fun ccidCommand(
        commandType: Int,
        commandSequence: Int,
        payload: ByteArray,
        params: ByteArray,
    ): ByteArray {
        val command = ByteArray(CCID_HEADER_SIZE + payload.size)
        command[0] = commandType.toByte()
        writeLe32(command, 1, payload.size)
        command[5] = SLOT_NUM.toByte()
        command[6] = commandSequence.toByte()
        for (index in 0 until minOf(params.size, CCID_PARAM_SIZE)) {
            command[7 + index] = params[index]
        }
        payload.copyInto(command, destinationOffset = CCID_HEADER_SIZE)
        return command
    }

    private fun writeBulk(bytes: ByteArray) {
        val activeConnection = connection ?: throw CcidException("USB connection is closed")
        val endpoint = bulkOut ?: throw CcidException("CCID bulk OUT endpoint is missing")
        val written = activeConnection.bulkTransfer(endpoint, bytes, bytes.size, USB_WRITE_TIMEOUT_MS)
        if (written != bytes.size) {
            throw CcidException("USB write length=$written expected=${bytes.size}")
        }
    }

    private fun readCcidResponse(
        expectedSequence: Int,
        expectedResponseType: Int,
        name: String,
    ): CcidResponse {
        var readTimeouts = 0
        for (attempt in 0 until CCID_RESPONSE_READ_ATTEMPTS) {
            val responseBytes =
                try {
                    readFullCcidResponse()
                } catch (_: CcidReadTimeoutException) {
                    readTimeouts += 1
                    continue
                }
            val responseType = responseBytes[0].toInt() and 0xFF
            val responseSequence = responseBytes[6].toInt() and 0xFF
            val status = responseBytes[7].toInt() and 0xFF
            val error = responseBytes[8].toInt() and 0xFF
            val payloadLength = readLe32(responseBytes, 1)
            val payload =
                if (payloadLength > 0) {
                    responseBytes.copyOfRange(CCID_HEADER_SIZE, CCID_HEADER_SIZE + payloadLength)
                } else {
                    ByteArray(0)
                }

            if (responseSequence != expectedSequence) {
                Log.d(
                    LOG_TAG,
                    "CCID stale response type=${hexByte(responseType)} seq=$responseSequence " +
                        "expectedSeq=$expectedSequence status=${hexByte(status)} data=${payload.hexPreview(32)}",
                )
                continue
            }
            if (responseType != expectedResponseType) {
                throw CcidException(
                    "CCID $name unexpected response type=${hexByte(responseType)} " +
                        "expected=${hexByte(expectedResponseType)}",
                )
            }

            when (status and CCID_COMMAND_STATUS_MASK) {
                CCID_COMMAND_STATUS_OK -> {
                    return CcidResponse(responseType, status, error, payload)
                }
                CCID_COMMAND_STATUS_TIME_EXTENSION -> {
                    Log.d(LOG_TAG, "CCID response pending command=$name seq=$responseSequence")
                    continue
                }
                else -> {
                    if ((status and CCID_SLOT_STATUS_MASK) == CCID_SLOT_STATUS_ABSENT) {
                        throw CardAbsentException("CCID card absent during $name")
                    }
                    throw CcidException(
                        "CCID $name failed status=${hexByte(status)} error=${hexByte(error)}",
                    )
                }
            }
        }
        throw CcidResponseTimeoutException(
            "CCID response timeout command=$name seq=$expectedSequence readTimeouts=$readTimeouts",
        )
    }

    private fun readFullCcidResponse(): ByteArray {
        val firstChunk = readBulk(USB_READ_TIMEOUT_MS)
        if (firstChunk.size < CCID_HEADER_SIZE) {
            throw CcidException("CCID response too short length=${firstChunk.size}")
        }

        val payloadLength = readLe32(firstChunk, 1)
        val totalLength = CCID_HEADER_SIZE + payloadLength
        if (totalLength > CCID_RESPONSE_BUFFER_SIZE) {
            throw CcidException("CCID response too large length=$totalLength")
        }
        if (firstChunk.size >= totalLength) return firstChunk.copyOf(totalLength)

        val output = ByteArrayOutputStream(totalLength)
        output.write(firstChunk)
        while (output.size() < totalLength) {
            output.write(readBulk(USB_READ_TIMEOUT_MS))
        }
        return output.toByteArray().copyOf(totalLength)
    }

    private fun readBulk(timeoutMs: Int): ByteArray {
        val activeConnection = connection ?: throw CcidException("USB connection is closed")
        val endpoint = bulkIn ?: throw CcidException("CCID bulk IN endpoint is missing")
        val buffer = ByteArray(CCID_RESPONSE_BUFFER_SIZE)
        val read = activeConnection.bulkTransfer(endpoint, buffer, buffer.size, timeoutMs)
        if (read <= 0) throw CcidReadTimeoutException("USB read timeout result=$read")
        return buffer.copyOf(read)
    }

    private fun flushPendingBulkResponses(reason: String) {
        val activeConnection = connection ?: return
        val endpoint = bulkIn ?: return
        val buffer = ByteArray(max(endpoint.maxPacketSize, BULK_FLUSH_BUFFER_SIZE))
        var flushed = 0
        while (flushed < BULK_FLUSH_ATTEMPTS) {
            val read = activeConnection.bulkTransfer(endpoint, buffer, buffer.size, BULK_FLUSH_TIMEOUT_MS)
            if (read <= 0) break
            flushed += 1
        }
        if (flushed > 0) {
            Log.d(LOG_TAG, "flushed stale CCID bulk responses count=$flushed reason=$reason")
        }
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

    private fun sleepPollingInterval() {
        Thread.sleep(POLL_INTERVAL_MS)
    }

    private fun sleepAfterError() {
        Thread.sleep(COMMUNICATION_ERROR_BACKOFF_MS)
    }

    private fun writeLe32(bytes: ByteArray, offset: Int, value: Int) {
        bytes[offset] = (value and 0xFF).toByte()
        bytes[offset + 1] = ((value shr 8) and 0xFF).toByte()
        bytes[offset + 2] = ((value shr 16) and 0xFF).toByte()
        bytes[offset + 3] = ((value shr 24) and 0xFF).toByte()
    }

    private fun readLe32(bytes: ByteArray, offset: Int): Int {
        return (bytes[offset].toInt() and 0xFF) or
            ((bytes[offset + 1].toInt() and 0xFF) shl 8) or
            ((bytes[offset + 2].toInt() and 0xFF) shl 16) or
            ((bytes[offset + 3].toInt() and 0xFF) shl 24)
    }

    companion object {
        private const val SLOT_NUM = 0
        private const val POLL_INTERVAL_MS = 150L
        private const val CARD_SETTLE_DELAY_MS = 450L
        private const val CARD_READ_ATTEMPTS = 3
        private const val CARD_READ_RETRY_DELAY_MS = 300L
        private const val COMMUNICATION_ERROR_BACKOFF_MS = 700L
        private const val COMMUNICATION_ERROR_INTERVAL_MS = 3_000L
        private const val USB_WRITE_TIMEOUT_MS = 1_000
        private const val USB_READ_TIMEOUT_MS = 500
        private const val BULK_FLUSH_ATTEMPTS = 32
        private const val BULK_FLUSH_BUFFER_SIZE = 64
        private const val BULK_FLUSH_TIMEOUT_MS = 100
        private const val TYPE2_NDEF_START_PAGE = 4
        private const val TYPE2_MAX_READ_PAGE = 64
        private const val TYPE2_PAGE_LENGTH = 4
        private const val TYPE2_NDEF_READ_ATTEMPTS = 3
        private const val TYPE2_PAGE_READ_ATTEMPTS = 3
        private const val TYPE2_PAGE_READ_RETRY_DELAY_MS = 120L
        private const val TYPE2_NDEF_READ_RETRY_DELAY_MS = 240L
        private const val CCID_HEADER_SIZE = 10
        private const val CCID_PARAM_SIZE = 3
        private const val CCID_RESPONSE_BUFFER_SIZE = 300
        private const val CCID_RESPONSE_READ_ATTEMPTS = 12
        private const val PC_TO_RDR_ICC_POWER_ON = 0x62
        private const val PC_TO_RDR_GET_SLOT_STATUS = 0x65
        private const val PC_TO_RDR_XFR_BLOCK = 0x6F
        private const val RDR_TO_PC_DATA_BLOCK = 0x80
        private const val RDR_TO_PC_SLOT_STATUS = 0x81
        private const val CCID_COMMAND_STATUS_MASK = 0xC0
        private const val CCID_COMMAND_STATUS_OK = 0x00
        private const val CCID_COMMAND_STATUS_TIME_EXTENSION = 0x80
        private const val CCID_SLOT_STATUS_MASK = 0x03
        private const val CCID_SLOT_STATUS_ABSENT = 0x02
        private val UTF_16_CHARSET: Charset = Charset.forName("UTF-16")
    }
}

private class CardAbsentException(message: String? = null) : Exception(message)
private open class CcidException(message: String) : Exception(message)
private class CcidReadTimeoutException(message: String) : CcidException(message)
private class CcidResponseTimeoutException(message: String) : CcidException(message)
private class NdefTextNotFoundException(message: String? = null) : Exception(message)
private class ApduStatusException(message: String) : Exception(message)

private fun Throwable.diagnosticMessage(): String {
    return "${this::class.java.simpleName}: ${message ?: "(no message)"}"
}

private fun ByteArray.hexPreview(limit: Int): String {
    return take(limit).joinToString(" ") { "%02X".format(it.toInt() and 0xFF) }
}

private fun hexByte(value: Int): String {
    return "%02X".format(value and 0xFF)
}
