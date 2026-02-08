import SwiftUI

enum ToastStyle {
    case success
    case warning
    case info

    var icon: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .success: return .green
        case .warning: return .yellow
        case .info: return .blue
        }
    }
}

struct ToastItem: Identifiable {
    let id = UUID()
    let message: String
    let style: ToastStyle
    let createdAt = Date()
}

class ToastManager: ObservableObject {
    static let shared = ToastManager()

    @Published var toasts: [ToastItem] = []

    private let maxToasts = 3
    private var dismissTimers: [UUID: Timer] = [:]

    private init() {}

    func show(_ message: String, style: ToastStyle = .info) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let toast = ToastItem(message: message, style: style)

            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                self.toasts.append(toast)
                // Trim to max
                if self.toasts.count > self.maxToasts {
                    let removed = self.toasts.removeFirst()
                    self.dismissTimers[removed.id]?.invalidate()
                    self.dismissTimers.removeValue(forKey: removed.id)
                }
            }

            // Auto-dismiss after 3 seconds
            self.dismissTimers[toast.id] = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
                self?.dismiss(toast.id)
            }
        }
    }

    func dismiss(_ id: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.dismissTimers[id]?.invalidate()
            self.dismissTimers.removeValue(forKey: id)
            withAnimation(.easeOut(duration: 0.25)) {
                self.toasts.removeAll { $0.id == id }
            }
        }
    }
}

struct ToastView: View {
    let toast: ToastItem

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.style.icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(toast.style.color)

            Text(toast.message)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 2)
        .transition(.asymmetric(
            insertion: .move(edge: .trailing).combined(with: .scale(scale: 0.8)).combined(with: .opacity),
            removal: .opacity
        ))
    }
}

struct ToastOverlay: View {
    @ObservedObject var toastManager = ToastManager.shared

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Spacer()
            ForEach(toastManager.toasts) { toast in
                ToastView(toast: toast)
            }
        }
        .padding(.trailing, 16)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .allowsHitTesting(false)
    }
}
