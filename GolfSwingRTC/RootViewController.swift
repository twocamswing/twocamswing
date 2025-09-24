import UIKit
import Network

final class RootViewController: UIViewController {

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
        label.text = "Golf Swing RTC"
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
