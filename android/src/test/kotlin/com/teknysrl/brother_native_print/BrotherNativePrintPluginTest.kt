package com.teknysrl.brother_native_print

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.mockito.Mockito
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/*
 * This demonstrates a simple unit test of the Kotlin portion of this plugin's implementation.
 *
 * Once you have built the plugin's example app, you can run these tests from the command
 * line by running `./gradlew testDebugUnitTest` in the `example/android/` directory, or
 * you can run them directly from IDEs that support JUnit such as Android Studio.
 */

internal class BrotherNativePrintPluginTest {
    @Test
    fun onMethodCall_getPlatformVersion_returnsExpectedValue() {
        val plugin = BrotherNativePrintPlugin()

        val call = MethodCall("getPlatformVersion", null)
        val mockResult: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(call, mockResult)

        Mockito.verify(mockResult).success("Android " + android.os.Build.VERSION.RELEASE)
    }

    @Test
    fun looksLikeBrotherDevice_filtersNonBrotherBluetoothDevices() {
        // Non-Brother Bluetooth/BLE device names are dropped.
        assertFalse(looksLikeBrotherDevice("P460D_F81C"))
        assertFalse(looksLikeBrotherDevice("WH-1000XM4"))
        assertFalse(looksLikeBrotherDevice(""))
        assertFalse(looksLikeBrotherDevice(null))
        // Brother device names (model or model + 4-digit suffix) are kept.
        assertTrue(looksLikeBrotherDevice("QL-820NWB1234"))
        assertTrue(looksLikeBrotherDevice("Brother RJ-2050"))
        assertTrue(looksLikeBrotherDevice("RJ-2050"))
        assertTrue(looksLikeBrotherDevice("TD-4550DNWB"))
        assertTrue(looksLikeBrotherDevice("PT-P900W"))
    }
}
