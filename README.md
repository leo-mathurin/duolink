# Duolink

Combine le Wi-Fi et le partage de connexion de l'iPhone sur un Mac, comme [Speedify](https://speedify.com), avec votre propre serveur. Pensé pour les connexions lentes ou instables, à la maison comme en déplacement : Duolink peut améliorer le débit et limiter les coupures en utilisant les deux liens.

> **Duolink est une simple preuve de concept (POC).** Il est expérimental et cassera probablement.

Le tunnel passe par un proxy : les applications doivent respecter le proxy système ou être configurées pour l'utiliser. Les autres se connectent directement.

![Menu Duolink](docs/menu.png)

## Fonctionnement

```
Apps du Mac
   │  proxy système (SOCKS5 + HTTP, 127.0.0.1:20802)
   ▼
sing-box (client Shadowsocks 2022, chiffré)
   │  TCP local (127.0.0.1:20801)
   ▼
Relais MPTCP (Network.framework)
   ├── sous-flux via le Wi-Fi ───────────┐
   └── sous-flux via l'iPhone en USB ────┤
                                         ▼
                       VPS : noyau Linux MPTCP + sing-box (serveur Shadowsocks)
                                         │
                                         ▼
                                     Internet
```

Une connexion **Multipath TCP** (RFC 8684) répartit les paquets d'un même flux sur plusieurs interfaces. Le serveur les remet dans l'ordre et sort sur Internet avec une seule IP. Un téléchargement unique peut ainsi profiter des deux liens, et la connexion peut être maintenue si l'un tombe et que l'autre reste disponible.

Duolink n'implémente aucun protocole lui-même. Il assemble des briques reconnues :

| Brique | Rôle |
|---|---|
| [MPTCP de macOS](https://developer.apple.com/documentation/network/nwparameters/multipathservicetype) | Le même que celui utilisé par Siri et Plans. Seul Network.framework l'expose aux apps tierces. |
| [MPTCP du noyau Linux](https://www.mptcp.dev) | Intégré au noyau depuis la version 5.6. |
| [sing-box](https://github.com/SagerNet/sing-box) | Proxy universel (plus de 38 000 étoiles). Fournit le chiffrement Shadowsocks 2022, le proxy local et le réglage du proxy système. |

Le code propre à Duolink est un petit relais en Swift et l'app de barre de menus. sing-box ne peut pas ouvrir de socket MPTCP sur macOS (Go ne le gère que sous Linux). Il parle donc en TCP simple au relais, et c'est le relais qui ouvre la connexion multichemin vers le serveur.

## Prérequis

- Un Mac sous macOS 14 ou plus récent, avec les outils Xcode et [Homebrew](https://brew.sh).
- Un accès Internet en Wi-Fi.
- Un iPhone avec un forfait de données autorisant le partage de connexion et un câble USB pour le relier au Mac.
- Un VPS Linux avec un noyau 5.15 ou plus récent et Docker. Choisissez-le proche de chez vous : chaque requête fait l'aller-retour par lui.

## Installation du serveur

Sur le VPS :

```sh
git clone https://github.com/leo-mathurin/duolink.git
cd duolink/server
./install.sh            # PORT=8443 par défaut
```

Le script :

- règle les limites MPTCP (8 sous-flux) avec un service systemd ;
- porte le tampon d'envoi TCP à 16 Mo, pour que le serveur alimente les deux liens à la fois ;
- active BBR, plus efficace sur les liens cellulaires qui perdent des paquets (`ENABLE_BBR=0` pour ne pas le faire) ;
- ouvre le port dans iptables, y compris dans `/etc/iptables/rules.v4` ;
- génère un mot de passe et lance sing-box dans Docker, en réseau `host` pour garder le MPTCP de bout en bout ;
- affiche un lien `ss://` à coller dans l'app.

Ouvrez aussi le port TCP choisi (8443 par défaut) dans le pare-feu de votre hébergeur.

<details>
<summary>Exemple pour Oracle Cloud (optionnel)</summary>

Sur Oracle Cloud, ajoutez une règle d'entrée TCP 8443 à la liste de sécurité du sous-réseau ou au groupe de sécurité réseau de l'instance, par exemple :

```sh
oci network nsg rules add --nsg-id <ocid-du-nsg> --security-rules \
  '[{"direction":"INGRESS","protocol":"6","source":"0.0.0.0/0","sourceType":"CIDR_BLOCK","tcpOptions":{"destinationPortRange":{"min":8443,"max":8443}}}]'
```

</details>

## Installation sur le Mac

```sh
brew install sing-box
git clone https://github.com/leo-mathurin/duolink.git
cd duolink
./scripts/build-app.sh --install
```

Puis, dans le menu Duolink :

1. Copiez le lien `ss://` affiché par le serveur et cliquez sur **Coller le lien ss://**.
2. Activez l'interrupteur. L'activation du tunnel ne demande pas de mot de passe administrateur ; les actions **Réparer** et **Optimiser** en demandent un.

## Utilisation

1. Connectez-vous au Wi-Fi. Si le réseau utilise un portail captif, validez-le avant d'activer Duolink.
2. Activez le partage de connexion sur l'iPhone et branchez-le **en USB**. Le Mac n'a qu'une carte Wi-Fi : il ne peut pas rejoindre deux réseaux Wi-Fi en même temps. Si Duolink propose **Réparer** ou **Optimiser**, consultez [Dépannage](#dépannage).
3. Les deux liens apparaissent dans le menu avec leur débit. En mode **Combiner**, un téléchargement peut utiliser les deux. Ces compteurs incluent aussi le trafic hors tunnel.

Si le Wi-Fi est connecté mais sans Internet (portail pas encore validé, accès Internet interrompu), une connexion qui n'aboutit pas en 2,5 secondes est relancée en évitant cette interface, donc via l'iPhone. Le Wi-Fi rejoint la connexion plus tard s'il revient.

### Modes

| Mode | Comportement |
|---|---|
| **Combiner** | Ouvre un sous-flux sur chaque connexion. Le serveur peut répartir les téléchargements sur les deux liens pour améliorer le débit. Les envois du Mac passent par une seule connexion à la fois. |
| **Secours** | Utilise un seul lien à la fois et vise à maintenir les connexions en basculant sur l'autre si le premier tombe. Peut réduire l'utilisation du forfait de l'iPhone. |

## Limites

- **Seules les apps qui respectent le proxy système passent par le tunnel** : navigateurs, la plupart des apps macOS, `curl` avec `-x`. Les autres sortent en direct, sans agrégation.
- **L'UDP passe dans le flux TCP** (UDP over TCP). Il est agrégé, mais un appel vidéo en UDP peut subir plus de latence qu'en direct. Les navigateurs n'utilisent pas QUIC à travers un proxy, ils restent donc en TCP agrégé.
- **Le gain dépend du réseau.** Les débits ne s'additionnent pas nécessairement. Si le Wi-Fi et l'iPhone dépendent du même réseau mobile, une panne peut affecter les deux. Quand un lien tombe, l'autre peut prendre le relais s'il reste disponible.
- **Portails captifs** : seuls `wifi.sncf`, `captive.apple.com`, les domaines `.local` et les adresses privées restent en direct. Sur un autre réseau, désactivez Duolink le temps de valider le portail.
- **Les envois ne s'additionnent pas** : un upload passe par une seule connexion à la fois (voir plus haut). Il bascule sur l'autre si elle est plus rapide ou si elle tombe.
- **Le trafic passant par l'iPhone consomme son forfait de données.** Le mode Secours peut réduire cette consommation, mais utilise aussi des données mobiles lorsqu'il passe par l'iPhone.
- **Si l'app est tuée brutalement**, le proxy système peut rester actif et couper Internet. Relancez Duolink : il arrête l'ancien sing-box et restaure le réglage. Sinon, désactivez les proxys dans Réglages Système > Réseau > Wi-Fi > Proxys.

### Exemple de mesure

Lors d'un essai avec un Wi-Fi à 11 Mo/s et une connexion 5G entre 20 et 24 Mo/s, Duolink a atteint 26 à 32 Mo/s, soit environ 30 % de plus que la 5G seule. Ces chiffres décrivent cet essai ; le gain peut varier sur votre connexion.

## Dépannage

### Le partage de connexion USB ne s'active pas

Sur macOS 26, l'interface « iPhone USB » peut rester éteinte : le Mac la crée mais ne l'active jamais, et l'iPhone ne démarre pas le partage. Duolink le détecte et propose **Réparer**. Cette action demande un mot de passe administrateur pour installer un LaunchDaemon, un service système qui active cette interface dès qu'elle apparaît.

À la main : `dist/duolinkctl fix-tethering | sudo sh`.

### Duolink propose « Optimiser »

Le LaunchDaemon agrandit aussi la fenêtre de réception TCP de macOS, de 4 à 8 Mo. Quand l'iPhone est branché et que ce réglage manque, le menu propose **Optimiser**. Cette action demande un mot de passe administrateur. macOS remet la valeur par défaut à chaque redémarrage, le LaunchDaemon la rétablit.

Lors d'un essai sous charge, la latence aller-retour (RTT) de la 5G est passée d'environ 20 à 200 ms. Dans ces conditions, la fenêtre de 4 Mo limitait le débit et Duolink était plus lent que la 5G seule. L'effet de ce réglage dépend de votre connexion.

### Le serveur ne répond plus

Le menu affiche une alerte rouge : les apps qui passent par le proxy n'ont alors plus Internet. Désactivez Duolink pour repasser en direct.

## Outil en ligne de commande

`duolinkctl` lance le même tunnel sans interface, pratique pour tester :

```sh
DUOLINK_LINK='ss://...' dist/duolinkctl                    # mode Combiner, proxy sur 127.0.0.1:20802
DUOLINK_LINK='ss://...' dist/duolinkctl backup --system-proxy
```

Pour vérifier que le serveur reçoit bien du MPTCP : `ss -Mni` sur le VPS liste les connexions MPTCP et leurs sous-flux.

## Désinstallation

```sh
rm -rf /Applications/Duolink.app ~/Library/Application\ Support/Duolink
```

Si vous avez utilisé **Réparer** ou **Optimiser** :

```sh
sudo launchctl bootout system/io.github.leo-mathurin.duolink.tethering
sudo rm /Library/LaunchDaemons/io.github.leo-mathurin.duolink.tethering.plist
```

Sur le serveur : `docker compose down` dans `server/`, puis `sudo systemctl disable --now duolink-mptcp`.

## Développement

```sh
cd client
swift test
```

Les tests couvrent l'analyse des liens `ss://`, la config sing-box (validée par `sing-box check` si le binaire est installé), le compteur de débit et le relais sur la boucle locale.

### Pourquoi pas le mode « aggregate » de macOS

macOS propose un mode MPTCP « aggregate », réservé aux apps tierces après un réglage root (`net.inet.mptcp.allow_aggregate`). Duolink n'utilise pas ce mode : l'ordonnanceur du noyau ne répartit les envois qu'entre une interface cellulaire et une interface non cellulaire, et le Wi-Fi comme l'iPhone en USB sont non cellulaires. Pour les téléchargements, la répartition entre les sous-flux est assurée côté serveur Linux.

## Licence

MIT
