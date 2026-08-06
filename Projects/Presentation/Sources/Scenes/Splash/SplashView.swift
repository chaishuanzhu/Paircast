import SwiftUI

/// Brand splash shown while `AppSession.bootstrap()` resolves login vs library.
public struct SplashView: View {
    @State private var markVisible = false
    @State private var titleVisible = false
    @State private var subtitleVisible = false
    @State private var glow = false

    public init() {}

    public var body: some View {
        ZStack {
            atmosphere
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 18) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(TandemColors.systemBlue.opacity(0.22))
                            .frame(width: 96, height: 96)
                            .blur(radius: glow ? 18 : 8)
                            .scaleEffect(glow ? 1.12 : 0.92)

                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.18, green: 0.52, blue: 1.0),
                                        TandemColors.systemBlue,
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 80, height: 80)
                            .overlay {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 28, weight: .bold))
                                    .foregroundStyle(.white)
                                    .offset(x: 2)
                            }
                            .shadow(color: TandemColors.systemBlue.opacity(0.35), radius: 18, y: 10)
                    }
                    .opacity(markVisible ? 1 : 0)
                    .scaleEffect(markVisible ? 1 : 0.82)

                    VStack(spacing: 8) {
                        Text("Tandem")
                            .font(.system(size: 42, weight: .bold, design: .rounded))
                            .tracking(-0.8)
                            .foregroundStyle(.white)
                            .opacity(titleVisible ? 1 : 0)
                            .offset(y: titleVisible ? 0 : 12)

                        Text("一起看电影")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.62))
                            .opacity(subtitleVisible ? 1 : 0)
                            .offset(y: subtitleVisible ? 0 : 8)
                    }
                }

                Spacer()

                ProgressView()
                    .tint(.white.opacity(0.55))
                    .opacity(subtitleVisible ? 1 : 0)
                    .padding(.bottom, 48)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tandem，一起看电影")
        .onAppear { runEntrance() }
    }

    private var atmosphere: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.07, blue: 0.12),
                    Color(red: 0.08, green: 0.12, blue: 0.22),
                    Color(red: 0.06, green: 0.09, blue: 0.16),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Soft cinema lamp — not decorative-only; anchors the brand mark.
            RadialGradient(
                colors: [
                    TandemColors.systemBlue.opacity(0.28),
                    Color.clear,
                ],
                center: .center,
                startRadius: 20,
                endRadius: 280
            )
            .offset(y: -40)
            .blendMode(.plusLighter)

            // Subtle film-grain-like vignette.
            RadialGradient(
                colors: [Color.clear, Color.black.opacity(0.45)],
                center: .center,
                startRadius: 120,
                endRadius: 520
            )
        }
    }

    private func runEntrance() {
        withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) {
            markVisible = true
        }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.86).delay(0.12)) {
            titleVisible = true
        }
        withAnimation(.easeOut(duration: 0.45).delay(0.22)) {
            subtitleVisible = true
        }
        withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true).delay(0.3)) {
            glow = true
        }
    }
}
