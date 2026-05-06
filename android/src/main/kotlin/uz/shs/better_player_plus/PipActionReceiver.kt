package uz.shs.better_player_plus

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

internal class PipActionReceiver(
    private val player: BetterPlayer,
    private val onStateChanged: () -> Unit,
) : BroadcastReceiver() {
    override fun onReceive(context: Context?, intent: Intent?) {
        when (intent?.action) {
            ACTION_REWIND -> player.nativeSkip(-SKIP_MS)
            ACTION_FORWARD -> player.nativeSkip(SKIP_MS)
            ACTION_TOGGLE -> player.togglePlayPause()
            else -> return
        }
        onStateChanged()
    }

    companion object {
        const val ACTION_REWIND = "uz.shs.better_player_plus.PIP_REWIND"
        const val ACTION_FORWARD = "uz.shs.better_player_plus.PIP_FORWARD"
        const val ACTION_TOGGLE = "uz.shs.better_player_plus.PIP_TOGGLE"
        const val SKIP_MS = 10_000L

        const val REQ_REWIND = 1001
        const val REQ_TOGGLE = 1002
        const val REQ_FORWARD = 1003
    }
}
