import SwiftUI

/// Personal usage breakdown for the last N days — reusable card (shown on the main Daily Insights
/// screen and in Progress). Loads its own snapshot from `env.usageStats`; on-device, site-aware.
struct UsageStatsCard: View {
    @Environment(AppEnvironment.self) private var env
    var days: Int = 7
    @State private var usage: UsageStatsService.Snapshot?

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("How you spent the last \(days) days").font(.headline)
                if let u = usage, !u.topApps.isEmpty {
                    HStack(spacing: 22) {
                        stat("Active/day", "\(u.avgMinutesPerActiveDay) min")
                        stat("Switches/day", "\(u.contextSwitchesPerDay)")
                        if let h = u.busiestHour { stat("Busiest hour", String(format: "%02d:00", h)) }
                    }
                    Divider()
                    Text("Where the time went").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    let maxM = max(1, u.topApps.map(\.minutes).max() ?? 1)
                    ForEach(u.topApps) { item in
                        HStack(spacing: 10) {
                            Text(item.label).font(.callout).lineLimit(1)
                                .frame(width: 190, alignment: .leading)
                            GeometryReader { geo in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(env.rewards.theme.accent.opacity(0.55))
                                    .frame(width: max(4, geo.size.width * CGFloat(item.minutes) / CGFloat(maxM)))
                            }
                            .frame(height: 10)
                            Text("\(item.minutes)m").font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
                        }
                    }
                    Text("Browsers are split by site (real host from your own history), not lumped as one app. On-device.")
                        .font(.caption2).foregroundStyle(.secondary)
                } else if usage != nil {
                    Text("Not enough activity yet — keep recording and this fills in.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Computing…").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .task { usage = await env.usageStats?.compute(days: days) }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.weight(.semibold).monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
