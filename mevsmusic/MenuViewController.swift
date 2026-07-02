import UIKit
import MediaPlayer
import UniformTypeIdentifiers

struct Track {
    let title: String
    let url: URL
}

// GameSettings.java port: the accelerometer toggle, persisted in UserDefaults.
enum GameSettings {
    private static let accelerometerKey = "AccelerometerEnabled"

    static var isAccelerometerEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: accelerometerKey) }
        set { UserDefaults.standard.set(newValue, forKey: accelerometerKey) }
    }
}

// MeVsMusicActivity.java port: the song menu — intro banner (tap for the options
// sheet), "Choose Your Music:", then the track list: the two demo tracks, a
// Files-picker entry, and the device music library (MPMediaQuery replaces
// MediaStore; tracks without a readable asset URL, e.g. DRM/cloud items, are
// skipped, as Android skipped non-file media).
final class MenuViewController: UIViewController {

    private enum Row {
        case track(Track)
        case pickFromDevice            // DEMO_TRACK3 ".. (pick a song from my device)"
    }

    private static let infoURL = "http://mevsmusic.netau.net/m/"
    private static let rowTextColor = UIColor(white: 1, alpha: 0.92)
    private static let gradientTop = UIColor(red: 0.02, green: 0.01, blue: 0.08, alpha: 1)
    private static let gradientBottom = UIColor(red: 0.09, green: 0.05, blue: 0.22, alpha: 1)

    private let gradient = CAGradientLayer()
    private let starfield = CAEmitterLayer()
    private let introView = UIImageView(image: UIImage(named: "logo.png"))
    private let chooseLabel = UILabel()
    private let optionsButton = UIButton(type: .system)
    private let tableView = UITableView()
    private var rows: [Row] = []

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()

        gradient.colors = [Self.gradientTop.cgColor, Self.gradientBottom.cgColor]
        view.layer.addSublayer(gradient)
        installStarfield()

        introView.contentMode = .scaleAspectFit
        introView.isUserInteractionEnabled = true
        introView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(showOptions)))

        chooseLabel.attributedText = NSAttributedString(
            string: "CHOOSE YOUR MUSIC",
            attributes: [.kern: 3.5])
        chooseLabel.font = {
            let base = UIFont.systemFont(ofSize: 14, weight: .semibold)
            let descriptor = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
            return UIFont(descriptor: descriptor, size: 14)
        }()
        chooseLabel.textColor = UIColor(white: 1, alpha: 0.55)
        chooseLabel.textAlignment = .center

        optionsButton.setImage(UIImage(systemName: "gearshape.fill",
                                       withConfiguration: UIImage.SymbolConfiguration(pointSize: 22)), for: .normal)
        optionsButton.tintColor = UIColor(white: 1, alpha: 0.75)
        optionsButton.addTarget(self, action: #selector(showOptions), for: .touchUpInside)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.rowHeight = 54

        for subview in [introView, chooseLabel, optionsButton, tableView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            introView.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
            introView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            introView.heightAnchor.constraint(lessThanOrEqualTo: view.heightAnchor, multiplier: 0.3),
            introView.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.55),

            optionsButton.topAnchor.constraint(equalTo: safe.topAnchor, constant: 12),
            optionsButton.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),

            chooseLabel.topAnchor.constraint(equalTo: introView.bottomAnchor, constant: 10),
            chooseLabel.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            chooseLabel.trailingAnchor.constraint(equalTo: safe.trailingAnchor),

            tableView.topAnchor.constraint(equalTo: chooseLabel.bottomAnchor, constant: 8),
            tableView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            tableView.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.62),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // Slowly drifting stars behind the menu.
    private func installStarfield() {
        starfield.emitterShape = .rectangle
        starfield.renderMode = .additive
        let star = CAEmitterCell()
        star.contents = UIImage(named: "flare.png")?.cgImage
        star.birthRate = 2.5
        star.lifetime = 40
        star.velocity = 8
        star.velocityRange = 6
        star.emissionRange = .pi * 2
        star.scale = 0.015
        star.scaleRange = 0.02
        star.alphaSpeed = -0.02
        star.color = UIColor(white: 1, alpha: 0.7).cgColor
        starfield.emitterCells = [star]
        view.layer.addSublayer(starfield)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        gradient.frame = view.bounds
        starfield.frame = view.bounds
        starfield.emitterSize = view.bounds.size
        starfield.emitterPosition = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
    }

    // Demo autopilot (DEMO env var, see GameRenderer): jump straight into the
    // bundled track so captures need no interaction.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard ProcessInfo.processInfo.environment["DEMO"] != nil, presentedViewController == nil,
              let url = Bundle.main.url(forResource: "Sunset", withExtension: "mp3") else { return }
        launch(Track(title: "Sunset.mp3", url: url))
    }

    // Android reloaded the list on every onResume.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if ProcessInfo.processInfo.environment["DEMO"] == nil,   // no prompts during captures
           MPMediaLibrary.authorizationStatus() == .notDetermined {
            MPMediaLibrary.requestAuthorization { _ in
                Task { @MainActor [weak self] in self?.loadList() }
            }
        }
        loadList()
    }

    // MARK: - Track list (FindTracks/getAllTracks port)

    private func loadList() {
        var rows: [Row] = ["Sunset", "FeelsGood2B"].compactMap { (name: String) in
            Bundle.main.url(forResource: name, withExtension: "mp3")
                .map { .track(Track(title: "\(name).mp3", url: $0)) }
        }
        rows.append(.pickFromDevice)
        rows += librarySongs()
        self.rows = rows
        tableView.reloadData()
    }

    private func librarySongs() -> [Row] {
        guard MPMediaLibrary.authorizationStatus() == .authorized,
              let items = MPMediaQuery.songs().items else { return [] }
        return items.compactMap { item in
            // Same intent as Android's IS_MUSIC + 10s minimum duration filter.
            guard let url = item.assetURL, item.playbackDuration >= 10 else { return nil }
            return .track(Track(title: item.title ?? url.lastPathComponent, url: url))
        }
    }

    private func launch(_ track: Track) {
        present(GameViewController(track: track,
                                   useAccelerometer: GameSettings.isAccelerometerEnabled),
                animated: true)
    }

    // MARK: - Options sheet (sb_main_menu port; Android opened it from the intro image)

    @objc private func showOptions() {
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Refresh", style: .default) { [weak self] _ in
            self?.loadList()
        })
        sheet.addAction(UIAlertAction(title: "Choose a File", style: .default) { [weak self] _ in
            self?.presentDocumentPicker()
        })
        let accelerometerTitle = GameSettings.isAccelerometerEnabled
            ? "Turn Accelerometer OFF" : "Turn Accelerometer ON"
        sheet.addAction(UIAlertAction(title: accelerometerTitle, style: .default) { _ in
            GameSettings.isAccelerometerEnabled.toggle()
        })
        sheet.addAction(UIAlertAction(title: "About", style: .default) { _ in
            if let url = URL(string: Self.infoURL) {
                UIApplication.shared.open(url)
            }
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = introView
        sheet.popoverPresentationController?.sourceRect = introView.bounds
        present(sheet, animated: true)
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(title: message, message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - Table

extension MenuViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "track")
            ?? UITableViewCell(style: .default, reuseIdentifier: "track")
        var content = cell.defaultContentConfiguration()
        switch rows[indexPath.row] {
        case .track(let track):
            content.text = track.title
            content.image = UIImage(systemName: "music.note")
        case .pickFromDevice:
            content.text = "Pick a song from my device…"
            content.image = UIImage(systemName: "folder")
        }
        content.textProperties.font = {
            let base = UIFont.systemFont(ofSize: 17, weight: .medium)
            let descriptor = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
            return UIFont(descriptor: descriptor, size: 17)
        }()
        content.textProperties.color = Self.rowTextColor
        content.imageProperties.tintColor = UIColor(red: 0.35, green: 0.9, blue: 1, alpha: 0.9)
        cell.contentConfiguration = content

        // Frosted card rows.
        var background = UIBackgroundConfiguration.clear()
        background.backgroundColor = UIColor(white: 1, alpha: 0.07)
        background.cornerRadius = 12
        background.backgroundInsets = NSDirectionalEdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0)
        cell.backgroundConfiguration = background
        cell.selectionStyle = .none
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch rows[indexPath.row] {
        case .track(let track):
            launch(track)
        case .pickFromDevice:
            presentDocumentPicker()
        }
    }
}

// MARK: - Files picker (OpenClicked/copyToCache port)

extension MenuViewController: UIDocumentPickerDelegate {

    private func presentDocumentPicker() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.audio])
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        // Copy into caches so playback outlives the security-scoped access
        // (the original copied content:// picks to the app cache for BASS).
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if isAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
                return
            }
            let destination = caches.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: url, to: destination)
            launch(Track(title: url.lastPathComponent, url: destination))
        } catch {
            showError("File Type Not Supported")
        }
    }
}
