import AVFoundation
import CatalogCore
import SwiftUI

private struct Lesson: Identifiable {
    let id: String
    let title: String
    let reading: String
    let question: String
    let choices: [String]
    let answer: Int

    static let samples = [
        Lesson(id: "compound", title: "米のとぎ方",
               reading: "最初の水は、ぬかのにおいが移る前に手早く捨てます。そのあと、水を替えながらやさしく洗います。",
               question: "最初の水はどうしますか？", choices: ["手早く捨てる", "一晩置く", "温める"], answer: 0),
        Lesson(id: "timer", title: "お茶のいれ方",
               reading: "煎茶は茶葉に合わせて湯の温度を調整します。沸騰したばかりの湯より、少し冷ました湯を使うのが目安です。",
               question: "煎茶をいれる湯の目安は？", choices: ["氷水を使う", "少し冷ました湯を使う", "必ず沸騰直後の湯を使う"], answer: 1),
        Lesson(id: "notes", title: "読書メモ",
               reading: "読んだ箇所と自分の考えを分けて記録します。あとで読み返す際に、出典と解釈を見分けられます。",
               question: "あとで見分けやすい記録方法は？", choices: ["記録を残さない", "自分の考えだけ書く", "出典と自分の考えを分ける"], answer: 2)
    ]
}

private struct LearningHistory: Codable, Sendable {
    var completed: [String: Date] = [:]
}

struct LearningSampleView: View {
    @Environment(\.diagnostics) private var diagnostics
    @State private var history: LocalRecords<LearningHistory>

    init(preview: Bool = false) {
        _history = State(initialValue: LocalRecords(initial: LearningHistory(), fileName: preview ? nil : "learning-v1.json"))
    }

    var body: some View {
        List {
            Section("進捗") {
                if history.ready {
                    let count = Lesson.samples.filter { history.value.completed[$0.id] != nil }.count
                    ProgressView(value: Double(count), total: Double(Lesson.samples.count)) {
                        Text("\(count) / \(Lesson.samples.count) 教材を修了")
                    }
                }
                LocalRecordStatus(store: history)
            }
            Section("教材") {
                ForEach(Lesson.samples) { lesson in
                    NavigationLink {
                        LessonView(lesson: lesson, history: history)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(lesson.title)
                            if let finished = history.value.completed[lesson.id] {
                                Text("修了 \(finished.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("短い教材で学ぶ")
        .task {
            await history.load()
            await diagnostics?.record(sample: .learning, action: .load, outcome: history.ready ? .success : .failure)
        }
    }
}

private struct LessonView: View {
    @Environment(\.diagnostics) private var diagnostics
    @Environment(\.scenePhase) private var scenePhase
    @State private var speech = AVSpeechSynthesizer()
    @State private var selected: Int?
    @State private var feedback: String?
    let lesson: Lesson
    let history: LocalRecords<LearningHistory>

    var body: some View {
        Form {
            Section("読む・聴く") {
                Text(lesson.reading)
                Button("読み上げる", systemImage: "speaker.wave.2") {
                    stopSpeech()
                    let utterance = AVSpeechUtterance(string: lesson.reading)
                    utterance.voice = AVSpeechSynthesisVoice(language: "ja-JP")
                    speech.speak(utterance)
                }
                Button("読み上げを止める", systemImage: "stop.circle", action: stopSpeech)
            }
            Section("理解を確かめる") {
                Text(lesson.question).font(.headline)
                Picker("回答", selection: $selected) {
                    Text("選んでください").tag(nil as Int?)
                    ForEach(lesson.choices.indices, id: \.self) { index in
                        Text(lesson.choices[index]).tag(Optional(index))
                    }
                }
                .onChange(of: selected) { feedback = nil }
                Button("回答を確認") { checkAnswer() }
                    .disabled(selected == nil || !history.canSave)
                if let feedback { Text(feedback).accessibilityAddTraits(.updatesFrequently) }
                LocalRecordStatus(store: history)
            }
        }
        .navigationTitle(lesson.title)
        .onDisappear(perform: stopSpeech)
        .onChange(of: scenePhase) { if scenePhase != .active { stopSpeech() } }
    }

    private func checkAnswer() {
        guard let selected else { return }
        guard selected == lesson.answer else {
            feedback = "教材を読み返して、もう一度選んでください。"
            return
        }
        if history.value.completed[lesson.id] != nil {
            feedback = "正解です。この教材は修了済みです。"
            return
        }
        var next = history.value
        next.completed[lesson.id] = Date()
        Task {
            let success = await history.save(next)
            feedback = success ? "正解です。修了を記録しました。" : "正解です。修了記録の保存を再試行してください。"
            await diagnostics?.record(sample: .learning, action: .save, outcome: success ? .success : .failure)
        }
    }

    private func stopSpeech() {
        speech.stopSpeaking(at: .immediate)
    }
}

#Preview {
    NavigationStack { LearningSampleView(preview: true) }
}
