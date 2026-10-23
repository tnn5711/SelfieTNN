import Combine
import SwiftUI
import UIKit

struct PasscodeEntryView: View {
    let title: String
    var message: String?
    var disabled = false
    let onComplete: (String) -> Void
    @State private var digits = ""

    private let rows = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"]]

    var body: some View {
        VStack(spacing: 26) {
            Text(title).font(.title3.bold())
            HStack(spacing: 18) {
                ForEach(0..<4, id: \.self) { i in
                    Circle().fill(i < digits.count ? Color.white : .clear)
                        .overlay(Circle().stroke(.white, lineWidth: 1.5))
                        .frame(width: 16, height: 16)
                }
            }
            Text(message ?? " ").font(.footnote).foregroundStyle(.red)
                .multilineTextAlignment(.center).frame(minHeight: 36)
            VStack(spacing: 14) {
                ForEach(rows, id: \.self) { row in
                    HStack(spacing: 22) { ForEach(row, id: \.self) { key($0) } }
                }
                HStack(spacing: 22) {
                    Color.clear.frame(width: 76, height: 76)
                    key("0")
                    Button { if !digits.isEmpty { digits.removeLast() } } label: {
                        Image(systemName: "delete.left").font(.title3).frame(width: 76, height: 76)
                    }
                    .accessibilityLabel("Delete")
                }
            }
        }
        .foregroundStyle(.white)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }

    private func key(_ d: String) -> some View {
        Button { tap(d) } label: {
            Text(d).font(.title).frame(width: 76, height: 76)
                .background(.white.opacity(0.15), in: Circle())
        }
    }

    private func tap(_ d: String) {
        guard digits.count < 4 else { return }
        digits += d
        if digits.count == 4 {
            let pin = digits
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                digits = ""
                onComplete(pin)
            }
        }
    }
}

/// Full-screen content of the lock window: keypad when locked, plain cover when merely inactive.
struct LockScreen: View {
    @ObservedObject private var lock = AppLock.shared

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if lock.isLocked {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let remaining = lock.remainingLockout(at: ctx.date)
                    PasscodeEntryView(
                        title: "Enter Passcode",
                        message: remaining > 0 ? "Too many attempts.\nTry again in \(remaining)s" : lock.errorMessage,
                        disabled: remaining > 0
                    ) { lock.attemptUnlock($0) }
                }
            } else {
                Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.white.opacity(0.6))
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// Shows the lock screen in its own window so it covers sheets, alerts and the app-switcher snapshot.
final class LockWindowController {
    static let shared = LockWindowController()
    private var window: UIWindow?
    private var previousKey: UIWindow?
    private var cancellable: AnyCancellable?

    func install() {
        guard cancellable == nil else { return }
        let lock = AppLock.shared
        cancellable = Publishers.CombineLatest(lock.$isLocked, lock.$isCovered)
            .receive(on: RunLoop.main)
            .sink { [weak self] locked, covered in
                locked || covered ? self?.show() : self?.hide()
            }
    }

    private func show() {
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return }
        previousKey = scene.windows.first(where: \.isKeyWindow)
        let w = UIWindow(windowScene: scene)
        w.windowLevel = .alert + 1
        w.rootViewController = UIHostingController(rootView: LockScreen())
        w.makeKeyAndVisible()
        window = w
    }

    private func hide() {
        window?.isHidden = true
        window = nil
        previousKey?.makeKey()
        previousKey = nil
    }
}
