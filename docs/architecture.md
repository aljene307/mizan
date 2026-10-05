# Architecture

> Ébauche. Le schéma complet sera produit à l'étape 9.

## Conteneurs (étape 0)

```
 navigateur ──► 127.0.0.1:5678 ──► n8n ──(port 5679, broker)──► runners
                                    │                          (nœuds Code)
                                    ▼
             127.0.0.1:5432 ──► postgres
                                 ├── base n8n    (tables internes de n8n)
                                 └── base mizan  (données métier, audit)

 ./data (hôte) ──lecture seule──► /data dans n8n
```
