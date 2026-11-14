package io.github.ccch1mneyyy.dsh_app.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import io.github.ccch1mneyyy.dsh_app.MainActivity
import io.github.ccch1mneyyy.dsh_app.R
import io.github.ccch1mneyyy.dsh_app.shortcuts.EntryActivity

/**
 * 桌面小组件「问一句 / 继续上次对话」。
 *
 * 两个按钮都走 App 自己的入口，不另开一套：
 *  - 问一句 → [EntryActivity] 的 NEW_CHAT，和长按图标里的「新对话」同一条路
 *  - 继续上次 → 直接回到 [MainActivity]，留在上次那个会话
 *
 * 只读系统给的状态，不自己存东西；点一下才启动 App，平时不耗电。
 */
class AskWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        for (id in ids) manager.updateAppWidget(id, views(context))
    }

    private fun views(context: Context): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.widget_ask)

        val ask = Intent(context, EntryActivity::class.java).setAction(EntryActivity.ACTION_NEW_CHAT)
        views.setOnClickPendingIntent(
            R.id.widget_ask,
            PendingIntent.getActivity(
                context, 1, ask,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            ),
        )

        val resume = Intent(context, MainActivity::class.java)
            .setAction(Intent.ACTION_MAIN)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        views.setOnClickPendingIntent(
            R.id.widget_resume,
            PendingIntent.getActivity(
                context, 2, resume,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            ),
        )
        return views
    }
}
