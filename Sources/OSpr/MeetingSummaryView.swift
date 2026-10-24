import OSprCore
import SwiftUI

struct MeetingSummaryView: View {
    @State private var expanded = true
    let summary: MeetingSummary
    let copy: () -> Void
    var body: some View {
        DisclosureGroup("Meeting summary · local AI", isExpanded: $expanded) {
            ScrollView {
                MeetingSummaryContent(summary: summary, copy: copy)
            }.frame(maxHeight: 280)
        }
    }
}

struct MeetingSummaryContent: View {
    let summary: MeetingSummary
    let copy: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Uses the original transcript; editor changes do not update these notes. AI paraphrases. Review the supporting quotes and full transcript for errors, omissions or unresolved conflicts. Actions are notes; OSpr does not execute them.")
                .font(.caption).foregroundStyle(.secondary)
            if summary.items.isEmpty { Text("The model returned no summary items. Review the original transcript.").foregroundStyle(.secondary) }
            ForEach(SummarySection.allCases, id: \.self) { section in
                let points = summary.items.filter { $0.section == section }
                if !points.isEmpty {
                    Text(section.title).font(.headline)
                    ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(point.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            DisclosureGroup(point.sourceIDs.count == 1 ? "Source \(point.sourceIDs[0] + 1)" : "\(point.sourceIDs.count) source quotes") {
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(point.sourceIDs, id: \.self) { id in
                                        if let excerpt = summary.excerpts.first(where: { $0.id == id }) {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text("SOURCE \(id + 1)").font(.caption2).foregroundStyle(.secondary)
                                                Text(excerpt.text).font(.callout).textSelection(.enabled)
                                                    .fixedSize(horizontal: false, vertical: true)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                            }
                                        }
                                    }
                                }
                            }.font(.caption)
                        }
                    }
                }
            }
            Button("Copy summary with sources as Markdown", action: copy)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
    }
}
