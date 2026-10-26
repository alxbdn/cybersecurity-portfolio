# Maquette Cisco Packet Tracer · P03

La maquette valide la partie réseau du cahier des charges avant le lab VMware : la segmentation en VLAN, la protection ARP par port, le téléphone VoIP de chaque utilisateur et l'accès SSH au switch depuis le poste d'administration. Elle reprend le plan d'adressage et la matrice des flux de `fw01`.

## Ce que le cahier des charges demande ici

| Exigence | Où dans la maquette |
|---|---|
| « La segmentation réseau est à réaliser sur Cisco Packet Tracer, avec les VLAN dédiés » | VLAN 10/20/30/40/50 sur `SW01`, routage inter-VLAN filtré sur `FW01` |
| « la protection ARP (limitation par port) » | port-security sticky sur chaque port, DHCP snooping + DAI avec `limit rate` sur le VLAN voix |
| « un téléphone VoIP par utilisateur, connecté au réseau » | 2 téléphones IP 7960 dans un VLAN voix, CME sur `FW01` |
| « Les postes d'administration ont accès au pare-feu, au switch […] en SSH » (fiche d'auto-évaluation) | SSHv2 sur `FW01` et `SW01`, filtré sur l'IP de `win01` |
| « J'ai indiqué le rôle de chaque commande » | chaque commande des fichiers de [`config/`](config/) est commentée |

## Topologie

```
  [Serveur Internet 203.0.113.10]
               │
            [ISP]  Gi0/1 203.0.113.254 · Gi0/0 198.51.100.1/30
               │
            [FW01] Gi0/1 198.51.100.2/30 (WAN, NAT)
               │   Gi0/0 trunk 802.1Q : .10 .20 .30 .40 .50  (passerelles .254)
               │
            [SW01] Gi0/1 trunk · management 10.0.30.253 (VLAN 30)
     ┌────────┬────┴─────────────┬──────────────────────┐
   Fa0/1    Fa0/2              Fa0/3                  Fa0/4
   web01    ad01         [Tél. 1001]──win01      [Tél. 1002]──win02
   VLAN 10  VLAN 20      voix 50 / data 30       voix 50 / data 40
```

## Matériel et câblage

| Équipement | Modèle Packet Tracer | Câble |
|---|---|---|
| FW01 | Routeur 2911 | Gi0/0 → SW01 Gi0/1 (droit) · Gi0/1 → ISP Gi0/0 (droit) |
| ISP | Routeur 2911 | Gi0/1 → Serveur Internet (droit) |
| SW01 | Switch 2960-24TT | voir ci-dessous |
| web01 | Server-PT | → SW01 Fa0/1 |
| ad01 | Server-PT | → SW01 Fa0/2 |
| Téléphone 1001 | IP Phone 7960 | port Switch du téléphone → SW01 Fa0/3, port PC → win01 |
| Téléphone 1002 | IP Phone 7960 | port Switch du téléphone → SW01 Fa0/4, port PC → win02 |
| win01 | PC-PT | → port PC du téléphone 1001 |
| win02 | PC-PT | → port PC du téléphone 1002 |
| Internet | Server-PT | → ISP Gi0/1 |

Les téléphones 7960 ont besoin de leur bloc d'alimentation : onglet *Physical* du téléphone, glisser l'adaptateur sur la prise.

## Plan d'adressage

| Zone | VLAN | Réseau | Passerelle | Machines |
|---|---|---|---|---|
| DMZ | 10 | 10.0.10.0/24 | 10.0.10.254 | web01 `.10` |
| Serveurs | 20 | 10.0.20.0/24 | 10.0.20.254 | ad01 `.10` |
| Admin | 30 | 10.0.30.0/24 | 10.0.30.254 | win01 `.10`, SW01 `.253` |
| Users | 40 | 10.0.40.0/24 | 10.0.40.254 | win02 `.10` |
| Voix | 50 | 10.0.50.0/24 | 10.0.50.254 | téléphones en DHCP (CME) |
| Natif du trunk | 998 | aucun | | VLAN vide |
| Parking | 999 | aucun | | ports inutilisés, éteints |
| WAN | | 198.51.100.0/30 | 198.51.100.1 | FW01 `.2` |
| Internet | | 203.0.113.0/24 | 203.0.113.254 | serveur externe `.10` |

Les adresses WAN et Internet sont des plages de documentation (RFC 5737) : elles ne correspondent à rien de réel.

## Ordre de montage

1. Poser et câbler les équipements (tableau ci-dessus).
2. Coller `config/ISP.txt`, puis `config/SW01.txt`, puis `config/FW01.txt` dans la CLI de chaque équipement (`enable`, `configure terminal`, coller). À `crypto key generate rsa`, répondre `2048`.
3. Configurer les terminaux en IP fixe (*Desktop > IP Configuration*) :

   | Machine | IP | Masque | Passerelle | DNS |
   |---|---|---|---|---|
   | web01 | 10.0.10.10 | 255.255.255.0 | 10.0.10.254 | |
   | ad01 | 10.0.20.10 | 255.255.255.0 | 10.0.20.254 | |
   | win01 | 10.0.30.10 | 255.255.255.0 | 10.0.30.254 | 10.0.20.10 |
   | win02 | 10.0.40.10 | 255.255.255.0 | 10.0.40.254 | 10.0.20.10 |
   | Internet | 203.0.113.10 | 255.255.255.0 | 203.0.113.254 | |

4. Services des serveurs (*Services*) :
   - web01 : HTTPS activé (une page « Site P03 »), HTTP désactivé.
   - ad01 : DNS activé, enregistrement A `web01.p03.lan` → `10.0.10.10`. Packet Tracer n'émule pas Active Directory : ad01 sert à prouver les flux DNS et le cloisonnement.
   - Internet : HTTP et HTTPS activés.
5. Laisser les téléphones démarrer : ils prennent une IP en 10.0.50.x et s'enregistrent (1001, 1002).
6. Dérouler les tests et faire une capture par test.

## Tests de recette

| # | Depuis | Action | Attendu | Ce que ça prouve |
|---|---|---|---|---|
| 1 | win02 | Navigateur `https://10.0.10.10` | Page du site | Users → web01 en HTTPS |
| 2 | win02 | Navigateur `https://203.0.113.10` | Page externe | Navigation Internet via NAT |
| 3 | Internet | Navigateur `https://198.51.100.2` | Page de web01 | Site publié (NAT statique 443) |
| 4 | win02 | `nslookup web01.p03.lan` | 10.0.10.10 | DNS du domaine via ad01 |
| 5 | win02 | `ping 10.0.30.10` | Échec | Users n'atteint pas Admin |
| 6 | win02 | `ssh -l netadmin 10.0.40.254` | Refusé | Un poste user n'administre pas FW01 |
| 7 | web01 | `ping 10.0.20.10` | Échec | DMZ n'atteint jamais le DC |
| 8 | win01 | `ping 10.0.20.10` puis `ping 10.0.10.10` | OK | Admin joint les zones |
| 9 | win01 | `ssh -l netadmin 10.0.30.253` | Prompt `SW01>` | SSH vers le switch |
| 10 | win01 | `ssh -l netadmin 10.0.30.254` | Prompt `FW01>` | SSH vers le pare-feu |
| 11 | Tél. 1002 | Composer 1001 | Le 1001 sonne | VoIP dans son VLAN |
| 12 | SW01 | Brancher un autre PC sur Fa0/1 à la place de web01, puis `show port-security interface fa0/1` | Compteur de violations > 0, trafic bloqué | Limitation MAC par port |
| 13 | SW01 | `show ip dhcp snooping binding` et `show ip arp inspection` | Les 2 téléphones listés | Protection ARP du VLAN voix |
| 14 | FW01 | `show access-lists` | Compteurs sur les lignes `deny` après les tests 5 à 7 | Les refus sont visibles |

## Commandes de vérification

| Commande | Équipement | Rôle |
|---|---|---|
| `show vlan brief` | SW01 | VLAN et ports associés |
| `show interfaces trunk` | SW01 | VLAN autorisés et VLAN natif du trunk |
| `show port-security` | SW01 | MAC apprises et violations par port |
| `show ip interface brief` | FW01 / SW01 | État et IP des interfaces |
| `show ip nat translations` | FW01 | Traductions NAT en cours |
| `show access-lists` | FW01 | Règles et nombre de paquets par règle |
| `show ip dhcp binding` | FW01 | Baux DHCP des téléphones |
| `show ephone registered` | FW01 | Téléphones enregistrés sur le CME |
| `show ssh` | FW01 / SW01 | Sessions SSH ouvertes |
| `show logging` | FW01 / SW01 | Journal local |

## Choix et proportionnalité

- **Un routeur 2911 plutôt qu'un ASA** : il porte à la fois le filtrage, le NAT et la téléphonie (CME), ce que l'ASA de Packet Tracer ne fait pas. Il reproduit `fw01` sans ajouter d'équipement.
- **Router-on-a-stick** : un trunk et cinq sous-interfaces suffisent à cette taille. Dans le lab VMware, `fw01` a une carte par zone ; la séparation logique est la même.
- **ACL sans état** : contrairement à nftables, une ACL Cisco ne suit pas les connexions. Les réponses passent par `established` (TCP) ou par port source (UDP), c'est la limite à citer en soutenance.
- **`violation restrict` plutôt que `shutdown`** : une MAC inconnue est bloquée et comptée, mais le poste légitime continue de fonctionner. Couper le port transformerait une erreur de câblage en panne.
- **DAI sur le VLAN voix seulement** : DAI s'appuie sur les baux DHCP. Les autres zones sont en IP fixe (exigence du cahier des charges) et sont protégées par port-security sticky.
- **Pas de QoS, de redondance ni de serveur syslog** : ce serait disproportionné pour deux postes. Les journaux restent en local, comme sur `fw01`.

## Fichiers

| Fichier | Contenu |
|---|---|
| [`config/FW01.txt`](config/FW01.txt) | Routeur/pare-feu : sous-interfaces, NAT, ACL, SSH, CME |
| [`config/SW01.txt`](config/SW01.txt) | Switch : VLAN, ports durcis, trunk, SSH, DHCP snooping, DAI |
| [`config/ISP.txt`](config/ISP.txt) | FAI simulé |
| `P03.pkt` | Maquette Packet Tracer (à enregistrer ici) |
