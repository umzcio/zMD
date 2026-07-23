import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject private var documentManager: DocumentManager
    @State private var showIcon = false
    @State private var showSubtitle = false
    @State private var showButton = false
    @State private var showHint = false
    @State private var showRecents = false
    @State private var iconBounce = false
    @State private var buttonHovered = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .scaleEffect(iconBounce ? 1.0 : 0.5)
                .opacity(showIcon ? 1 : 0)
                .padding(.bottom, 16)

            Text("Markdown Editor & Viewer")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .opacity(showSubtitle ? 1 : 0)
                .offset(y: showSubtitle ? 0 : 8)

            HStack(spacing: 12) {
                Button(action: documentManager.createNewFile) {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.badge.plus")
                            .font(.system(size: 14))
                        Text("New File")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.accentColor.opacity(0.6), lineWidth: 1.5)
                    )
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(PressableButtonStyle())

                Button(action: documentManager.openFile) {
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .font(.system(size: 14))
                        Text("Open File")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(buttonHovered ? Color.accentColor : Color.accentColor.opacity(0.85))
                    )
                    .foregroundStyle(.white)
                    .scaleEffect(buttonHovered ? 1.03 : 1.0)
                }
                .buttonStyle(PressableButtonStyle())
                .onHover { hovering in
                    withAnimation(Motion.fast) {
                        buttonHovered = hovering
                    }
                }
            }
            .opacity(showButton ? 1 : 0)
            .offset(y: showButton ? 0 : 8)
            .padding(.top, 24)

            HStack(spacing: 4) {
                Text("or press")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(NSColor.tertiaryLabelColor))
                Text("⌘O")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(NSColor.controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
                    )
            }
            .opacity(showHint ? 1 : 0)
            .padding(.top, 12)

            if !documentManager.recentFileURLs.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("RECENT FILES")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color(NSColor.tertiaryLabelColor))

                        Spacer()

                        Button("Clear") {
                            withAnimation(Motion.entrance) {
                                documentManager.clearRecentFiles()
                            }
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(Color(NSColor.tertiaryLabelColor))
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            if hovering {
                                NSCursor.pointingHand.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)

                    ForEach(documentManager.recentFileURLs.prefix(5), id: \.path) { url in
                        Button {
                            documentManager.loadDocument(from: url)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "doc.text")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(url.lastPathComponent)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(url.deletingLastPathComponent().path)
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color(NSColor.tertiaryLabelColor))
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(RecentFileButtonStyle())
                    }
                }
                .frame(width: 320)
                .padding(.top, 28)
                .opacity(showRecents ? 1 : 0)
                .offset(y: showRecents ? 0 : 8)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
        .onAppear(perform: animateEntrance)
    }

    private func animateEntrance() {
        if Motion.reduceMotion {
            withAnimation(.easeOut(duration: 0.2)) {
                showIcon = true
                iconBounce = true
                showSubtitle = true
                showButton = true
                showHint = true
                showRecents = true
            }
            return
        }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
            showIcon = true
            iconBounce = true
        }
        withAnimation(.easeOut(duration: 0.35).delay(0.10)) {
            showSubtitle = true
        }
        withAnimation(.easeOut(duration: 0.35).delay(0.16)) {
            showButton = true
        }
        withAnimation(.easeOut(duration: 0.35).delay(0.22)) {
            showHint = true
        }
        withAnimation(.easeOut(duration: 0.35).delay(0.28)) {
            showRecents = true
        }
    }
}
