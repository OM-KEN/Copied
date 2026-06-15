import SwiftUI

struct ToastView: View {
    let viewModel: ToastViewModel

    @State private var animateIn = false

    var body: some View {
        HStack(spacing: 12) {
            if let thumbnail = viewModel.thumbnailImage {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                Image(systemName: viewModel.iconSymbolName)
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(viewModel.previewText)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(String(localized: "复制自"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        if let icon = viewModel.sourceAppIcon {
                            Image(nsImage: icon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 16, height: 16)
                        }
                        Text(viewModel.sourceAppName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    if !viewModel.detailInfo.isEmpty {
                        Text(viewModel.detailInfo)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: 360)
        .padding(16)
        .glassEffect(in: .rect(cornerRadius: 32))
        .overlay {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .stroke(.white.opacity(0.25), lineWidth: 0.8)
        }
        // ── Entry spring: card flies from above + scales up ──
        // At start: scale=0.2 blur=12 → tiny blurry dot, clipping invisible.
        // By the time it's visible, it's already within bounds.
        .scaleEffect(animateIn ? 1 : 0.2)
        .offset(y: animateIn ? 0 : -56)
        .blur(radius: animateIn ? 0 : 12)
        .opacity(animateIn ? 1 : 0)
        .padding(.top, 20)
        .padding(.bottom, 12)
        .padding(.horizontal, 18)
        .onAppear {
            withAnimation(.interpolatingSpring(
                mass: 1.2,
                stiffness: 120,
                damping: 14,
                initialVelocity: 3
            )) {
                animateIn = true
            }
        }
    }
}
