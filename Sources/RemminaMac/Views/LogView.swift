import SwiftUI

/// Log viewer showing app debug entries.
struct LogView: View {
    @State private var logger = AppLogger.shared

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Application Logs")
                    .font(.title3)
                    .fontWeight(.bold)
                Spacer()
                Text("\(logger.entries.count) entries")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Clear") {
                    logger.clear()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(16)

            Divider()

            // Log entries
            if logger.entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("No log entries")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(logger.entries) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Text(entry.timestamp, format: .dateTime.hour().minute().second())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 70, alignment: .leading)

                            Text(entry.level.rawValue)
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundStyle(logLevelColor(entry.level))
                                .frame(width: 40)

                            Text(entry.message)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                        }
                        .id(entry.id)
                    }
                    .listStyle(.plain)
                    .onChange(of: logger.entries.count) { _, _ in
                        if let last = logger.entries.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private func logLevelColor(_ level: AppLogger.LogLevel) -> Color {
        switch level {
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        case .debug: return .gray
        }
    }
}
