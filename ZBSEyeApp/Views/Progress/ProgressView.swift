import SwiftUI

/// Compact progress panel: streak, milestones, memory age, progress bar to the next milestone.
struct MemoryProgressView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var usage: UsageStatsService.Snapshot?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Progress").font(.largeTitle.bold())
                statsCard
                usageCard
                milestonesCard
            }
            .padding(28)
            .frame(maxWidth: 680, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .task {
            await env.progress?.refresh()
            usage = await env.usageStats?.compute(days: 7)
        }
    }

    // MARK: — Usage card (last 7 days, site-aware)

    @ViewBuilder
    private var usageCard: some View {
        if let u = usage, !u.topApps.isEmpty {
            GlassCard {
                VStack(alignment: .leading, spacing: 14) {
                    Text("How you spent the last \(u.days) days").font(.headline)
                    HStack(spacing: 20) {
                        statCell(label: "Active/day", value: "\(u.avgMinutesPerActiveDay) min")
                        statCell(label: "Context switches/day", value: "\(u.contextSwitchesPerDay)")
                        if let h = u.busiestHour {
                            statCell(label: "Busiest hour", value: String(format: "%02d:00", h))
                        }
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
                            Text("\(item.minutes)m").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                .frame(width: 48, alignment: .trailing)
                        }
                    }
                    Text("Browsers are split by site (real host from your own history), not lumped as one app. On-device.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: — Stats card

    private var statsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                Text("Your memory").font(.headline)
                if let p = env.progress {
                    let s = p.snapshot
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                              alignment: .leading, spacing: 12) {
                        statCell(label: "Frames",
                                 value: NumberFormatter.localizedString(
                                    from: NSNumber(value: s.totalFrames), number: .decimal))
                        statCell(label: "Streak",
                                 value: streakLabel(s.streakDays))
                        statCell(label: "Days used",
                                 value: "\(s.totalDays)")
                        statCell(label: "Memory age",
                                 value: ageDaysLabel(s.memoryAgeDays))
                    }

                    if s.totalFrames > 0 {
                        Divider()
                        nextMilestoneRow(s)
                    }
                } else if let err = env.dataError {
                    // Honest-state: DB didn't come up — a hard error, not "still loading".
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Database not loaded yet")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func nextMilestoneRow(_ s: ProgressSnapshot) -> some View {
        if let next = s.nextMilestone {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("To the \(NumberFormatter.localizedString(from: NSNumber(value: next), number: .decimal)) milestone")
                        .font(.callout)
                    Spacer()
                    Text(progressLabel(s))
                        .font(.caption).foregroundStyle(.secondary)
                }
                ProgressBar(value: s.progressToNext)
            }
        } else {
            // Passed all milestones
            Label("All milestones passed — you're among the pioneers of forever memory.",
                  systemImage: "star.fill")
                .font(.callout).foregroundStyle(.yellow)
        }
    }

    private func progressLabel(_ s: ProgressSnapshot) -> String {
        guard let next = s.nextMilestone else { return "" }
        let prev = s.lastMilestone ?? 0
        let remaining = max(0, next - s.totalFrames)
        let r = NumberFormatter.localizedString(from: NSNumber(value: remaining), number: .decimal)
        let _ = prev   // suppress warning
        return "\(r) to go"
    }

    // MARK: — Milestones card

    private var milestonesCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Memory milestones").font(.headline)
                Text("Each milestone is a piece of life saved locally, forever.")
                    .font(.caption).foregroundStyle(.secondary)
                let total = env.progress?.snapshot.totalFrames ?? 0
                ForEach(MemoryMilestones.frames, id: \.self) { m in
                    MilestoneRow(milestone: m, reached: total >= m, current: total)
                }
            }
        }
    }

    // MARK: — Helpers

    private func statCell(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold())
        }
    }

    private func streakLabel(_ days: Int) -> String {
        switch days {
        case 0: return "—"
        case 1: return "1 day"
        default: return "\(days) days"
        }
    }

    private func ageDaysLabel(_ days: Int) -> String {
        if days == 0 { return "less than a day" }
        switch days {
        case 1: return "1 day"
        default: return "\(days) days"
        }
    }
}

// MARK: — Sub-components

private struct ProgressBar: View {
    let value: Double   // 0...1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.secondary.opacity(0.18))
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(barGradient)
                    .frame(width: max(0, geo.size.width * value))
            }
        }
        .frame(height: 8)
        .animation(reduceMotion ? nil : .spring(duration: 0.6), value: value)
    }

    private var barGradient: LinearGradient {
        LinearGradient(
            colors: [Color(hue: 0.72, saturation: 0.7, brightness: 0.65),
                     Color(hue: 0.52, saturation: 0.8, brightness: 0.7)],
            startPoint: .leading, endPoint: .trailing)
    }
}

private struct MilestoneRow: View {
    let milestone: Int
    let reached: Bool
    let current: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: reached ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(reached ? Color.purple : Color.secondary.opacity(0.5))
                .font(.callout)
                .frame(width: 18)
            Text(NumberFormatter.localizedString(from: NSNumber(value: milestone), number: .decimal))
                .font(.callout)
                .foregroundStyle(reached ? .primary : .secondary)
            Spacer()
            if reached {
                Text("reached").font(.caption2).foregroundStyle(.secondary)
            } else if current > 0 {
                let pct = Int(min(99, Double(current) / Double(milestone) * 100))
                Text("\(pct)%").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
