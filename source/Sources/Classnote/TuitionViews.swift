import SwiftUI
import ClassnoteCore

extension AppModel {
    func lectureTitle(_ lecture: Lecture) -> String {
        lecture.displayTitle(courseName: courses.first { $0.id == lecture.courseID }?.name)
    }
    func openCustomPreferences() { settingsSection = 1; showSettings = true }
    var tuitionPlan: TuitionPlan? { settings.tuition.map { TuitionPlan(configuration: $0, schedule: schedule) } }
}

struct TuitionIndicator: View {
    @ObservedObject var model: AppModel
    @State private var showsDetail = false
    private var configuration: TuitionConfiguration? { model.settings.tuition }
    private var lecture: Lecture? { model.displayed }
    private var included: Bool { guard let lecture, let configuration else { return false }; return TuitionPlan.includes(lecture, configuration: configuration) }
    private var amount: Double? {
        guard let configuration, let plan = model.tuitionPlan else { return nil }
        if let lecture { return included ? plan.amount(seconds: lecture.activeSeconds, configuration: configuration) : nil }
        return plan.amount(seconds: TuitionPlan.recordedSeconds(model.lectures, configuration: configuration), configuration: configuration)
    }
    var body: some View {
        if configuration?.showsIndicator != false {
            Button {
                if configuration?.hasValidFee == true { showsDetail.toggle() }
                else { model.openCustomPreferences() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "graduationcap").font(.system(size: 11))
                    if let amount, let configuration {
                        Text(lecture?.isDemo == true ? "演示" : (lecture == nil ? "学期" : "本节"))
                        Text(configuration.money(amount)).monospacedDigit()
                    } else { Text(configuration?.hasValidFee == true ? (included || lecture == nil ? "课时待设置" : "学期外") : "设置学费") }
                }.font(.system(size: 11)).foregroundStyle(.white.opacity(0.64)).lineLimit(1)
            }.buttonStyle(.plain).help("按计划课时折算学费；点击查看明细或设置")
                .accessibilityLabel(amount.map { "学费折算 \(configuration?.money($0) ?? "")，查看明细" } ?? "学费设置与明细")
                .popover(isPresented: $showsDetail, arrowEdge: .bottom) { detail }
        }
    }
    private var detail: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("学费折算").font(.system(size: 15, weight: .medium))
            if let configuration, let plan = model.tuitionPlan {
                if let lecture {
                    row("本节有效收音", formatTime(lecture.activeSeconds))
                    row(lecture.isDemo ? "本节演示金额" : "本节已值回", amount.map(configuration.money) ?? "未计入")
                }
                let total = TuitionPlan.recordedSeconds(model.lectures, configuration: configuration)
                row("本学期累计", plan.amount(seconds: total, configuration: configuration).map(configuration.money) ?? "—")
                row("计划课时", String(format: "%.1f 小时", plan.hours))
                row("开始使用", "第 \(min(max(configuration.usageStartWeek, 1), configuration.semesterWeekCount())) 周")
                if configuration.hoursSource == .timetable && !plan.coversSemester {
                    Text("课表没有覆盖全部统计周期").font(.system(size: 11)).foregroundStyle(.orange)
                }
            }
            Button("打开自定义偏好") { showsDetail = false; model.openCustomPreferences() }.buttonStyle(QuietButton())
        }.padding(20).frame(width: 290).background(Palette.bg).foregroundStyle(.white).preferredColorScheme(.dark)
    }
    private func row(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(Palette.dim); Spacer(); Text(value).monospacedDigit() }.font(.system(size: 12))
    }
}

struct TuitionPreferences: View {
    @ObservedObject var model: AppModel
    @State private var value = TuitionConfiguration()
    @State private var fee = ""
    @State private var hours = ""
    @State private var feedback = ""
    private var plan: TuitionPlan { TuitionPlan(configuration: draft, schedule: model.schedule) }
    private var draft: TuitionConfiguration {
        var copy = value; copy.fee = number(fee) ?? 0; copy.manualHours = number(hours) ?? 0; return copy
    }
    private var valid: Bool { draft.hasValidFee && draft.interval() != nil && plan.seconds > 0 }
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("学费与学期").font(.system(size: 12, weight: .medium))
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 7) { Text("本学期学费").font(.system(size: 11)); TextField("输入金额", text: $fee).textFieldStyle(.roundedBorder).accessibilityLabel("本学期学费") }
                Picker("币种", selection: $value.currency) { Text("GBP · £").tag("GBP"); Text("CNY · ¥").tag("CNY"); Text("USD · $").tag("USD"); Text("EUR · €").tag("EUR") }.frame(width: 160)
            }
            HStack {
                DatePicker("开始", selection: $value.semesterStart, displayedComponents: .date)
                Spacer()
                DatePicker("结束", selection: $value.semesterEnd, displayedComponents: .date)
            }.datePickerStyle(.field).font(.system(size: 11))
            HStack {
                Text("开始使用周").font(.system(size: 11))
                Spacer()
                Stepper(value: $value.usageStartWeek, in: 1...max(1, value.semesterWeekCount())) {
                    Text("第 \(min(max(value.usageStartWeek, 1), value.semesterWeekCount())) 周").monospacedDigit()
                }.controlSize(.small)
            }.help("从第几周开始使用 Classnote；此前的计划课程默认已上，之后按实际有效收音累计。")
            Picker("计划课时", selection: $value.hoursSource) {
                Text("从课表统计").tag(TuitionHoursSource.timetable)
                Text("手动填写").tag(TuitionHoursSource.manual)
            }.pickerStyle(.segmented)
            if value.hoursSource == .manual {
                HStack { Text("学期总课时（小时）").font(.system(size: 11)); TextField("例如 160", text: $hours).textFieldStyle(.roundedBorder).accessibilityLabel("学期总课时（小时）") }
            } else {
                Text("\(plan.classCount) 节课 · \(plan.hours.formatted(.number.precision(.fractionLength(1)))) 小时").font(.system(size: 12)).monospacedDigit()
                if !plan.coversSemester {
                    Text("课表没有覆盖全部统计周期").font(.system(size: 11)).foregroundStyle(.orange)
                }
            }
            Toggle("在主窗口顶部显示学费折算", isOn: $value.showsIndicator).font(.system(size: 12))
            if let sample = plan.amount(seconds: 50 * 60, configuration: draft) {
                Text("50 分钟 · \(draft.money(sample))").font(.system(size: 11)).foregroundStyle(.white.opacity(0.66))
            }
            if draft.interval() == nil { Text("学期日期无效，请选择不超过 370 天的范围。").font(.system(size: 11)).foregroundStyle(.orange) }
            HStack {
                Button("保存学费设置") { model.settings.tuition = draft; model.saveSettings(); feedback = "已保存，顶部金额会按新设置更新。" }
                    .buttonStyle(QuietButton()).disabled(!valid)
                if model.settings.tuition != nil {
                    Button("清除学费设置") { model.settings.tuition = nil; model.saveSettings(); fee = ""; feedback = "学费设置已清除。" }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.dim)
                }
            }
            if !feedback.isEmpty { Text(feedback).font(.system(size: 11)).foregroundStyle(Palette.mint) }
        }
        .onAppear {
            if let stored = model.settings.tuition { value = stored }
            else if let start = model.schedule.sources.filter(\.enabled).map(\.from).min(),
                    let end = model.schedule.sources.filter(\.enabled).map(\.through).max() {
                value.semesterStart = start
                value.semesterEnd = Calendar.current.date(byAdding: .day, value: -1, to: end) ?? end
            }
            fee = value.fee > 0 ? String(value.fee) : ""; hours = value.manualHours > 0 ? String(value.manualHours) : ""
        }
        .onChange(of: value) { _, _ in feedback = "" }
        .onChange(of: fee) { _, _ in feedback = "" }
        .onChange(of: hours) { _, _ in feedback = "" }
    }
    private func number(_ text: String) -> Double? {
        let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
        return value?.isFinite == true ? value : nil
    }
}
