package app.floor.android.onboarding

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Looper
import androidx.core.content.ContextCompat
import androidx.core.location.LocationManagerCompat
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.resume

/**
 * One fix from the platform's `LocationManager` (no Play services), within [timeoutMillis]: the
 * network provider for an approximate grant, GPS when precise is allowed and on. The point is
 * handed to one request and kept nowhere.
 */
class AndroidLocation(private val context: Context, private val timeoutMillis: Long = 15_000) : LocationProvider {
    private val manager = context.getSystemService(LocationManager::class.java)

    /** Location services on for the whole phone. */
    val servicesOn: Boolean get() = manager != null && LocationManagerCompat.isLocationEnabled(manager)

    fun granted(permission: String) = ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

    /** What the system allows now, without asking. */
    fun access(): LocationAccess = when {
        !servicesOn -> LocationAccess.SERVICES_OFF
        granted(Manifest.permission.ACCESS_FINE_LOCATION) -> LocationAccess.PRECISE
        granted(Manifest.permission.ACCESS_COARSE_LOCATION) -> LocationAccess.APPROXIMATE
        else -> LocationAccess.DENIED
    }

    @SuppressLint("MissingPermission")
    override suspend fun current(): Coordinate? {
        val manager = manager ?: return null
        val precise = granted(Manifest.permission.ACCESS_FINE_LOCATION)
        if (!precise && !granted(Manifest.permission.ACCESS_COARSE_LOCATION)) return null
        val provider = listOfNotNull(
            if (precise && manager.isProviderEnabled(LocationManager.GPS_PROVIDER)) LocationManager.GPS_PROVIDER else null,
            if (manager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)) LocationManager.NETWORK_PROVIDER else null,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && manager.isProviderEnabled(LocationManager.FUSED_PROVIDER)) LocationManager.FUSED_PROVIDER else null,
        ).firstOrNull() ?: return null
        val fix = withTimeoutOrNull(timeoutMillis) {
            suspendCancellableCoroutine<Location?> { continuation ->
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    val cancel = android.os.CancellationSignal()
                    continuation.invokeOnCancellation { cancel.cancel() }
                    manager.getCurrentLocation(provider, cancel, ContextCompat.getMainExecutor(context)) { continuation.resume(it) }
                } else {
                    val listener = LocationListener { if (continuation.isActive) continuation.resume(it) }
                    continuation.invokeOnCancellation { manager.removeUpdates(listener) }
                    @Suppress("DEPRECATION")
                    manager.requestSingleUpdate(provider, listener, Looper.getMainLooper())
                }
            }
        }
        return fix?.let { Coordinate(it.latitude, it.longitude) }
    }
}
