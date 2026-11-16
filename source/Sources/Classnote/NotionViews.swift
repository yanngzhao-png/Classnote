import SwiftUI
import ClassnoteCore

struct NotionPreferences: View {
    @ObservedObject var model: AppModel
    @State private var token = ""
    @State private var saved = false
    @State private var checking = false
    @State private var feedback = ""
    @State private var disconnect = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Notion").font(.system(size: 16, weight: .medium))
                VStack(alignment: .leading, spacing: 10) {
                    Text("1 · 连接 Notion").font(.system(size: 12, weight: .semibold))
                    Link("打开 Notion 连接管理 ↗", destination: URL(string: "https://app.notion.com/developers/connections")!).font(.system(size: 12)).foregroundStyle(Palette.mint)
                    SecureField(saved ? "已保存；留空可检查现有连接" : "Notion 连接凭证（ntn_… / secret_…）", text: $token).textFieldStyle(.roundedBorder)
                    HStack {
                        Button(checking ? "检查中…" : (token.isEmpty ? "检查连接" : "保存并检查连接")) { check() }.buttonStyle(QuietButton()).disabled(checking || model.notionSyncingID != nil)
                        if saved {
                            Text("已存入钥匙串").font(.system(size: 10)).foregroundStyle(Palette.mint); Spacer()
                            Button("断开连接") { disconnect = true }.buttonStyle(.plain).font(.system(size: 11)).disabled(model.notionSyncingID != nil || !model.notionQueue.isEmpty)
                        }
                    }
                    if !feedback.isEmpty { Text(feedback).font(.system(size: 11)).foregroundStyle(Palette.mint).textSelection(.enabled) }
                }.padding(16).background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
                Toggle("课堂整理完成后自动归档", isOn: Binding(get: { model.notionConfiguration.automatic }, set: { model.setNotionAutomatic($0) })).disabled(!saved)
                Toggle("同步完整音频原文（英文 + 中文）", isOn: Binding(get: { model.notionConfiguration.includeTranscript }, set: { model.setNotionIncludeTranscript($0) })).disabled(!saved)
                Divider().overlay(Palette.line)
                Text("2 · 绑定已有课程页面").font(.system(size: 12, weight: .semibold))
                ForEach(model.courseGroups) { course in NotionCourseBinding(model: model, course: course, connected: saved).id(course.id) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { saved = (try? Keychain.readNotion().isEmpty == false) ?? false }
        .alert("断开 Notion 连接？", isPresented: $disconnect) {
            Button("取消", role: .cancel) {}
            Button("断开", role: .destructive) {
                do { try Keychain.removeNotion(); model.setNotionAutomatic(false); saved = false; feedback = "已移除本机凭证；课程绑定和已有 Notion 页面保留。" }
                catch { feedback = error.localizedDescription }
            }
        } message: { Text("将移除本机 Notion 凭证并关闭自动归档。已有笔记和页面不会删除。") }
    }
    private func check() {
        checking = true; feedback = ""
        Task {
            defer { checking = false }
            do {
                let entered = token.trimmingCharacters(in: .whitespacesAndNewlines)
                let value = try entered.isEmpty ? Keychain.readNotion() : entered
                guard !value.isEmpty else { throw NotionFailure("请先粘贴 Notion 连接凭证。") }
                _ = try await NotionClient(token: value).checkConnection()
                if !entered.isEmpty { try Keychain.saveNotion(entered); token = "" }
                saved = true; feedback = "连接成功。接下来验证课程页面；页面读取成功后仍需一次实际上传确认写入权限。"
            } catch { feedback = error.localizedDescription }
        }
    }
}
struct NotionCourseBinding: View {
    @ObservedObject var model: AppModel
    let course: Course
    let connected: Bool
    @State private var link = ""
    @State private var checking = false
    @State private var feedback = ""
    @State private var meetingLink = ""
    @State private var meetingChoices: [NotionMeetingTarget] = []
    private var target: NotionPageTarget? { model.notionConfiguration.mappings[course.id.uuidString] }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(course.name).font(.system(size: 13, weight: .medium)); Spacer()
                if let target {
                    Button("打开已绑定页面") { model.openNotionPage(target) }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Palette.mint)
                    Button("解除绑定") { model.unbindNotionPage(course); link = ""; feedback = "绑定已解除，已有课堂归档保留。" }.buttonStyle(.plain).font(.system(size: 10)).disabled(checking)
                }
            }
            if let target {
                Text("已绑定：" + target.title).font(.system(size: 11)).foregroundStyle(Palette.mint)
                Text(target.meetings.map { "会议列表：" + $0.title } ?? "课程页").font(.system(size: 11)).foregroundStyle(Palette.dim)
            }
            HStack {
                TextField("粘贴这门课已有的 Notion 页面链接", text: $link).textFieldStyle(.roundedBorder)
                Button(checking ? "验证中…" : "验证并绑定") {
                    checking = true; feedback = ""
                    Task {
                        defer { checking = false }
                        do {
                            let id = try NotionPageTarget.pageID(link)
                            let page = try await NotionClient(token: Keychain.readNotion()).page(id)
                            var bound = page
                            if target?.id == page.id { bound.meetings = target?.meetings }
                            model.bindNotionPage(bound, to: course); link = page.url; feedback = "页面可读取，已绑定。"
                        } catch { feedback = error.localizedDescription }
                    }
                }.buttonStyle(QuietButton()).disabled(checking || !connected || link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let target {
                HStack {
                TextField("会议数据库或数据源链接", text: $meetingLink).textFieldStyle(.roundedBorder)
                    Button(checking ? "验证中…" : "绑定会议列表") {
                        checking = true; feedback = ""; meetingChoices = []
                        Task {
                            defer { checking = false }
                            do {
                                let choices = try await NotionClient(token: Keychain.readNotion()).meetingTargets(databaseLink: meetingLink, courseID: target.id)
                                if choices.count == 1, let choice = choices.first { useMeetings(choice, target: target) }
                                else { meetingChoices = choices; feedback = "此数据库有多个适用列表，请选择。" }
                            } catch { feedback = error.localizedDescription }
                        }
                    }.buttonStyle(QuietButton()).disabled(checking || !connected || meetingLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ForEach(meetingChoices, id: \.dataSourceID) { choice in
                    Button("使用「\(choice.title)」") { useMeetings(choice, target: target) }.buttonStyle(.plain)
                }
            }
            if !feedback.isEmpty { Text(feedback).font(.system(size: 11)).foregroundStyle(Palette.dim).textSelection(.enabled) }
        }.padding(14).background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
            .onAppear { link = target?.url ?? "" }
    }
    private func useMeetings(_ choice: NotionMeetingTarget, target: NotionPageTarget) {
        var updated = target; updated.meetings = choice
        model.bindNotionPage(updated, to: course); meetingChoices = []
        feedback = "已绑定会议列表；之后的新归档会先进入列表，再尽量填写课程、日期和类型。"
    }
}
struct NotionArchiveStatus: View {
    @ObservedObject var model: AppModel
    let lecture: Lecture
    private var record: NotionArchiveRecord? { model.notionArchives[lecture.id] }
    private var working: Bool { model.notionSyncingID == lecture.id || model.notionQueue.contains(lecture.id) }
    private var current: Bool { record?.isCurrent(for: model.notionPayload(lecture)) == true }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Palette.dim)
                if working { ProgressView().controlSize(.mini); Text(model.notionSyncingID == lecture.id ? model.notionProgress : "等待同步…") }
                else if record?.phase == .failed { Text("Notion 同步未完成").foregroundStyle(.orange) }
                else if current { Image(systemName: "checkmark").foregroundStyle(Palette.mint).help("已同步到 Notion") }
                else if record?.page != nil { Text("Notion 有待更新的内容") }
                else { Text("Notion 归档") }
                Spacer()
                if model.notionMeetingMigrationTarget(lecture) != nil {
                    Button(record?.relocation == nil ? "移入会议列表" : "重试移入会议") { model.moveNotionArchiveToMeetings(lecture) }.buttonStyle(.plain).disabled(working)
                }
                if let page = record?.page {
                    Button { model.openNotionPage(page) } label: { Image(systemName: "arrow.up.right.square") }
                        .buttonStyle(.plain).help("打开 Notion 页面").accessibilityLabel("打开 Notion 页面")
                    if record?.phase == .failed {
                        rebuildButton
                    } else {
                        Menu { rebuildButton } label: { Image(systemName: "ellipsis") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            .help("归档操作").accessibilityLabel("Notion 归档操作").disabled(working)
                    }
                }
                if model.notionTarget(for: lecture) == nil {
                    Button("绑定课程页面") { model.openNotionPreferences() }.buttonStyle(.plain)
                } else {
                    Button(record?.phase == .failed ? "重试同步" : (current ? "已同步" : (record?.page == nil ? "同步到 Notion" : "更新归档"))) { model.queueNotion(lecture.id) }
                        .buttonStyle(.plain).disabled(working || current || (record?.job == nil && record?.relocation == nil && record?.replacement == nil && model.notionReadiness(lecture) != nil))
                }
            }.font(.system(size: 11)).foregroundStyle(Palette.dim)
            if let error = record?.error { Text(error).font(.system(size: 10)).foregroundStyle(.orange).textSelection(.enabled) }
            if let warning = record?.meetingWarning { Text(warning).font(.system(size: 10)).foregroundStyle(.orange).textSelection(.enabled) }
            else if !working, !current, let reason = model.notionReadiness(lecture), model.notionTarget(for: lecture) != nil { Text(reason).font(.system(size: 10)).foregroundStyle(Palette.dim) }
        }
    }
    private var rebuildButton: some View {
        Button("重建页面") { model.rebuildNotionArchive(lecture.id) }
            .buttonStyle(.plain).disabled(working || model.notionReadiness(lecture) != nil)
            .help("已在 Notion 删除原归档时，用最新笔记在当前课程绑定位置重建；先核对旧页和目标权限，保留本地资料。")
    }
}
