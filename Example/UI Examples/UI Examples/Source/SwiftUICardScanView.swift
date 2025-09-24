//
//  SwiftUICardScanView.swift
//  UI Examples
//
//  Created by Stripe on 2024.
//  Copyright © 2024 Stripe. All rights reserved.
//

import StripeCardScan
import SwiftUI
import UIKit

struct SwiftUICardScanView: View {

    @State private var isPresentingScanner = false
    @State private var scannedCard: ScannedCard?
    @State private var statusMessage: String?
    @State private var statusTint: Color = .secondary

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 32)

            VStack(spacing: 8) {
                Text("SwiftUI Card Scan")
                    .font(.largeTitle)
                    .bold()

                Text("Present the native camera experience inside a SwiftUI flow and react to scan updates in real time.")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)

            if let scannedCard {
                CardScanResultView(card: scannedCard)
                    .transition(.opacity)
            } else {
                Text("No card scanned yet")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }

            Button {
                statusMessage = nil
                statusTint = .secondary
                isPresentingScanner = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "camera.fill")
                    Text("Scan card")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .background(Color.accentColor)
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(.horizontal)

            if let statusMessage {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundColor(statusTint)
            }

            Spacer()
        }
        .padding(.vertical)
        .background(Color(uiColor: .systemBackground))
        .sheet(isPresented: $isPresentingScanner) {
            CardScannerRepresentable(isPresented: $isPresentingScanner) { result in
                switch result {
                case .completed(let card):
                    withAnimation {
                        scannedCard = card
                        statusMessage = "Scanned card saved"
                        statusTint = .green
                    }
                case .canceled:
                    statusMessage = "Scan canceled"
                    statusTint = .secondary
                case .failed(let error):
                    statusMessage = error.localizedDescription
                    statusTint = .red
                }
            }
            .ignoresSafeArea()
        }
    }
}

private struct CardScanResultView: View {
    let card: ScannedCard

    private var formattedPan: String {
        let trimmed = card.pan.replacingOccurrences(of: " ", with: "")
        guard trimmed.count > 4 else { return card.pan }
        let lastFour = trimmed.suffix(4)
        return "•••• " + lastFour
    }

    private var formattedExpiry: String {
        guard let month = card.expiryMonth, let year = card.expiryYear else {
            return ""
        }
        return "Expires \(month)/\(year)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Scanned card")
                .font(.headline)
            Text(formattedPan)
                .font(.title2)
                .bold()
            if !formattedExpiry.isEmpty {
                Text(formattedExpiry)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            if let name = card.name, !name.isEmpty {
                Text(name)
                    .font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .padding(.horizontal)
    }
}

private struct CardScannerRepresentable: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onCompletion: (CardScanSheetResult) -> Void

    func makeUIViewController(context: Context) -> DemoScanViewController {
        let controller = DemoScanViewController()
        controller.delegate = context.coordinator
        controller.scanPerformancePriority = .accurate
        controller.maxErrorCorrectionDuration = 8
        return controller
    }

    func updateUIViewController(_ uiViewController: DemoScanViewController, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, SimpleScanDelegate {
        var parent: CardScannerRepresentable

        init(parent: CardScannerRepresentable) {
            self.parent = parent
        }

        func userDidCancelSimple(_ scanViewController: SimpleScanViewController) {
            parent.isPresented = false
            parent.onCompletion(.canceled)
        }

        func userDidScanCardSimple(
            _ scanViewController: SimpleScanViewController,
            creditCard: CreditCard
        ) {
            parent.isPresented = false
            parent.onCompletion(.completed(card: ScannedCard(scannedCard: creditCard)))
        }
    }
}

private final class DemoScanViewController: SimpleScanViewController {
    override func setupUiComponents() {
        super.setupUiComponents()
        view.backgroundColor = UIColor.systemIndigo
        descriptionText.text = "Align your card inside the frame"
        descriptionText.textColor = .white
        descriptionText.font = UIFont.preferredFont(forTextStyle: .title2)
        descriptionText.numberOfLines = 2

        closeButton.setTitle("Done", for: .normal)
        torchButton.setTitle("Light", for: .normal)

        if let torchImage = UIImage(systemName: "flashlight.on.fill") {
            torchButton.setImage(torchImage, for: .normal)
            torchButton.tintColor = .white
            torchButton.imageEdgeInsets = UIEdgeInsets(top: 0, left: -4, bottom: 0, right: 4)
        }

        roiView.layer.borderColor = UIColor.systemGreen.cgColor
        roiView.layer.borderWidth = 3
        roiView.layer.cornerRadius = 18

        enableCameraPermissionsButton.setTitleColor(.white, for: .normal)
        enableCameraPermissionsText.textColor = .white
        privacyLinkText.textColor = .white
        privacyLinkText.linkTextAttributes = [
            .foregroundColor: UIColor.systemTeal,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        privacyLinkText.backgroundColor = .clear
    }
}

struct SwiftUICardScanView_Previews: PreviewProvider {
    static var previews: some View {
        SwiftUICardScanView()
    }
}
