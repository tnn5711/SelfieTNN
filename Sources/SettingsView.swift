import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showChange = false
    @State private var isDefault = PasscodeStore.isDefault

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Change Passcode") { showChange = true }
                } footer: {
                    if isDefault {
                        Text("You're still using the default passcode. Please change it.")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showChange, onDismiss: { isDefault = PasscodeStore.isDefault }) {
                ChangePasscodeView()
            }
        }
    }
}

private struct ChangePasscodeView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var lock = AppLock.shared

    private enum Step: Equatable { case current, new, confirm(String), done }
    @State private var step = Step.current
    @State private var message: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack {
                HStack { Spacer(); Button("Cancel") { dismiss() }.padding() }
                Spacer()
                content
                Spacer()
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .current:
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let remaining = lock.remainingLockout(at: ctx.date)
                PasscodeEntryView(title: "Enter Current Passcode",
                                  message: remaining > 0 ? "Too many attempts.\nTry again in \(remaining)s" : message,
                                  disabled: remaining > 0) { pin in
                    if lock.check(pin) { message = nil; step = .new }
                    else { message = "Incorrect passcode" }
                }
            }
        case .new:
            PasscodeEntryView(title: "Enter New Passcode", message: message) { pin in
                message = nil
                step = .confirm(pin)
            }
        case .confirm(let first):
            PasscodeEntryView(title: "Confirm New Passcode", message: message) { pin in
                if pin == first {
                    PasscodeStore.set(pin)
                    step = .done
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { dismiss() }
                } else {
                    message = "Passcodes didn't match. Try again."
                    step = .new
                }
            }
        case .done:
            Label("Passcode changed", systemImage: "checkmark.circle.fill")
                .font(.title3).foregroundStyle(.white)
        }
    }
}
