import UIKit
import Network

final class RootViewController: UIViewController {

    private enum AutoRole: String {
        case sender
        case receiver

        init?(environmentValue: String?) {
            guard let value = environmentValue?.lowercased() else { return nil }
            self.init(rawValue: value)
        }
    }

    private var didAutoLaunch = false

    private func triggerLocalNetworkPermission() {
        let params = NWParameters.udp
        let conn = NWConnection(host: "224.0.0.251", port: 5353, using: params) // mDNS group
        conn.stateUpdateHandler = { state in
            print("Local network check state: \(state)")
        }
        conn.start(queue: .main)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        triggerLocalNetworkPermission()
        
        // Title label
        let label = UILabel()
        label.text = "Two Cam Swing"
        label.font = UIFont.systemFont(ofSize: 24, weight: .bold)
        label.textAlignment = .center

        // Sender button
        let senderButton = UIButton(type: .system)
        senderButton.setTitle("Start as Sender (Camera)", for: .normal)
        senderButton.addTarget(self, action: #selector(startSender), for: .touchUpInside)

        // Receiver button
        let receiverButton = UIButton(type: .system)
        receiverButton.setTitle("Start as Receiver (Viewer)", for: .normal)
        receiverButton.addTarget(self, action: #selector(startReceiver), for: .touchUpInside)

        // Stack layout
        let stack = UIStackView(arrangedSubviews: [label, senderButton, receiverButton])
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.alignment = .center

        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        guard !didAutoLaunch else { return }
        didAutoLaunch = true

        switch AutoRole(environmentValue: ProcessInfo.processInfo.environment["AUTO_ROLE"]) {
        case .sender:
            startSender()
        case .receiver:
            startReceiver()
        case .none:
            break
        }
    }

    @objc private func startSender() {
        let vc = SenderViewController()
        vc.modalPresentationStyle = .fullScreen
        present(vc, animated: true)
    }

    @objc private func startReceiver() {
        let vc = ReceiverViewController()
        vc.modalPresentationStyle = .fullScreen
        present(vc, animated: true)
    }
}
