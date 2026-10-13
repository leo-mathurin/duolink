import DuolinkCore
import SwiftUI

struct MenuView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            if model.server == nil {
                noServer
            } else {
                linksSection
                tunnelSection
            }
            if let notice = model.notice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Duolink").font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { model.isOn }, set: { model.setEnabled($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(model.server == nil)
        }
    }

    private var noServer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Aucun serveur configuré.").font(.callout)
            Text("Lancez server/install.sh sur votre VPS, copiez le lien ss:// affiché, puis collez-le ici.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Coller le lien ss://") { model.importLinkFromClipboard() }
        }
    }

    private var linksSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Connexions").font(.subheadline.weight(.semibold))
            if model.links.isEmpty {
                Text("Aucune connexion réseau.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.links) { link in
                HStack {
                    Image(systemName: link.kind.symbol)
                        .frame(width: 18)
                        .foregroundStyle(.secondary)
                    Text(link.name).lineLimit(1)
                    Spacer()
                    RateLabel(rates: link.rates)
                }
                .font(.callout)
            }
            if model.links.count < 2 {
                Text("Branchez l'iPhone en USB avec le partage de connexion actif pour ajouter un deuxième lien.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var tunnelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tunnel").font(.subheadline.weight(.semibold))
                Spacer()
                if model.isOn {
                    RateLabel(rates: model.tunnelRates).font(.callout)
                }
            }
            Picker("Mode", selection: $model.mode) {
                Text("Agréger").tag(MultipathMode.aggregate)
                Text("Réactif").tag(MultipathMode.interactive)
                Text("Secours").tag(MultipathMode.handover)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(model.mode.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.mode == .aggregate && !model.aggregateAllowed {
                VStack(alignment: .leading, spacing: 6) {
                    Text("macOS bloque l'agrégation par défaut. En attendant, Duolink utilise le mode Réactif.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Autoriser l'agrégation (mot de passe admin)") { model.allowAggregate() }
                        .controlSize(.small)
                }
                .padding(8)
                .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            }

            if model.serverUnreachable {
                Text("Le serveur ne répond pas. Les apps qui passent par Duolink n'ont plus Internet : vérifiez le VPS ou désactivez Duolink.")
                    .font(.caption)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.isOn {
                Text("\(model.stats.activeConnections) connexions actives, \(model.stats.connectionsOpened) au total")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.server != nil {
                Button("Remplacer le serveur (coller un lien ss://)") { model.importLinkFromClipboard() }
            }
            Toggle("Lancer à l'ouverture de session", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            HStack {
                Button("Journal") { model.openLog() }
                Spacer()
                Button("Quitter") { model.quit() }.keyboardShortcut("q")
            }
        }
        .buttonStyle(.link)
        .font(.callout)
    }

    private var statusText: String {
        switch model.status {
        case .stopped: model.server == nil ? "Non configuré" : "Arrêté"
        case .starting: "Démarrage…"
        case .running: "Actif via \(model.server?.host ?? "")"
        case .failed(let message): message
        }
    }

    private var statusColor: Color {
        switch model.status {
        case .running: .green
        case .failed: .red
        default: .secondary
        }
    }
}

struct RateLabel: View {
    let rates: Throughput

    var body: some View {
        Text("↓ \(Self.format(rates.down))  ↑ \(Self.format(rates.up))")
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }

    static func format(_ bytesPerSecond: Double) -> String {
        let bits = bytesPerSecond * 8
        if bits >= 1_000_000 { return String(format: "%.1f Mb/s", bits / 1_000_000) }
        return String(format: "%.0f kb/s", bits / 1_000)
    }
}

extension LinkStatus.Kind {
    var symbol: String {
        switch self {
        case .wifi: "wifi"
        case .iPhone: "iphone"
        case .ethernet: "cable.connector"
        case .cellular: "antenna.radiowaves.left.and.right"
        }
    }
}

extension MultipathMode {
    var explanation: String {
        switch self {
        case .aggregate: "Additionne le débit de toutes les connexions."
        case .interactive: "Utilise la connexion la plus rapide et déborde sur l'autre si besoin."
        case .handover: "Utilise une seule connexion et bascule sans coupure si elle tombe."
        case .disabled: ""
        }
    }
}
