# 🏗️ Arquitectura

## 🔄 Flujo de datos

Todos los recursos están en el grupo `rg-agroeco-dev`, pero en **dos regiones**:
**Spain Central** para todo salvo SQL, y **France Central** para el servidor y la base de datos SQL
(la oferta gratuita no está disponible en Spain Central para la suscripción de prueba; ver README,
"Decisiones técnicas").

```
                    ┌─────────────── Spain Central ───────────────────────────────────────────┐
                    │                                                                          │
 ┌──────────────┐   │  ┌────────────────────────────────┐      ┌─────────────────────────────┐ │
 │ Temporizador │───┼─>│ Function App (Flex Consumption) │      │ Storage Account             │ │
 │ día 1, 06:00 │   │  │ func-agroeco-dev-XXXXX          │      │ stagroecodevXXXXX           │ │
 └──────────────┘   │  │                                 │ 2 ──>│  raw/AAAA-MM-DD/*.tsv       │ │
 ┌──────────────┐   │  │  pipeline_mensual (timer)       │ 4 ──>│  processed/AAAA-MM-DD/*.csv │ │
 │ Petición POST│───┼─>│  pipeline_manual  (HTTP)        │      │  despliegue/ (código)       │ │
 │ (pruebas)    │   │  │                                 │      └─────────────────────────────┘ │
 └──────────────┘   │  │  src/pipeline.py                │                                      │
 ┌──────────────┐ 1 │  │   1. descarga.py                │      ┌─────────────────────────────┐ │
 │ API Eurostat │<──┼──│   3. limpieza.py                │ logs │ Application Insights        │ │
 └──────────────┘   │  │   5. carga_sql.py               │ ────>│ appi-agroeco-dev            │ │
                    │  └───────────────┬─────────────────┘      │  → log-agroeco-dev          │ │
                    │                  │                        └─────────────────────────────┘ │
                    └──────────────────┼───────────────────────────────────────────────────────┘
                                       │ 5  (conexión cifrada, puerto 1433)
                    ┌──────────────────┼────── France Central ──────┐
                    │                  v                             │
                    │  ┌────────────────────────────────────────┐   │
                    │  │ Azure SQL Database (oferta gratuita)   │   │
                    │  │ sql-agroeco-dev-XXXXX / sqldb-agroeco  │   │
                    │  │ modelo en estrella (6 tablas + vista)  │   │
                    │  └───────────────────┬────────────────────┘   │
                    └──────────────────────┼────────────────────────┘
                                           v
                    Portal (Query editor) o notebook → sql/02_consultas_analisis.sql
```

1. La Function descarga las 4 tablas de la API de Eurostat.
2. Guarda los TSV originales en `raw/` (una carpeta por fecha → histórico).
3. Los limpia con pandas (mismo código que el proyecto original).
4. Guarda las 6 tablas limpias en CSV en `processed/`.
5. Borra y vuelve a crear el esquema en Azure SQL y carga las tablas, todo en una transacción.

## 🏷️ Convención de nombres

Formato: **`<abreviatura>-<prefijo>-<entorno>[-<sufijo>]`**

| Parte | Valor | Explicación |
|---|---|---|
| abreviatura | `rg`, `st`, `sql`... | Las [recomendadas por Microsoft](https://learn.microsoft.com/es-es/azure/cloud-adoption-framework/ready/azure-best-practices/resource-abbreviations) |
| prefijo | `agroeco` | Común a todo el proyecto (parámetro `prefijo` del Bicep) |
| entorno | `dev` | Permite tener en el futuro `prod` sin choques de nombres |
| sufijo | 5 caracteres (`uniqueString`) | Solo en recursos cuyo nombre debe ser **único en todo Azure**. Se calcula a partir del ID de la suscripción, así que siempre sale el mismo |

| Recurso | Nombre | ¿Único global? |
|---|---|---|
| Grupo de recursos | `rg-agroeco-dev` | No |
| Storage Account | `stagroecodev<sufijo>` (sin guiones: Azure solo admite minúsculas y números) | Sí |
| Servidor SQL (France Central) | `sql-agroeco-dev-<sufijo>` | Sí |
| Base de datos SQL (France Central) | `sqldb-agroeco` | No |
| Plan de Functions | `asp-agroeco-dev` | No |
| Function App | `func-agroeco-dev-<sufijo>` | Sí |
| Application Insights | `appi-agroeco-dev` | No |
| Log Analytics | `log-agroeco-dev` | No |
| Action Group (correo de alertas) | `ag-agroeco-dev` | No |
| Alerta de métrica (fallos de la Function) | `alerta-fallos-agroeco-dev` | No |
| Presupuesto (suscripción) | `presupuesto-agroeco` | No |

Todos los recursos llevan las etiquetas `proyecto=agroeco`, `entorno=dev` y `gestionadoPor=bicep`.

## 📦 Cómo se empaqueta el código

```
Repositorio                         Paquete .zip que recibe Azure
───────────                         ─────────────────────────────
function_app/function_app.py   ──>  function_app.py
function_app/host.json         ──>  host.json
function_app/requirements.txt  ──>  requirements.txt
src/*.py                       ──>  src/*.py
sql/*.sql                      ──>  sql/*.sql
```

`scripts/empaquetar.py` crea el zip y Azure instala las dependencias en Linux
(*remote build*). Así `src/` existe una sola vez en el repositorio y lo pueden usar
tanto la Function como las ejecuciones locales (`python -m src.pipeline`).

## 🔐 Secretos e identidades (Fase 3B)

| Secreto o identidad | Dónde vive | Dónde NO está |
|---|---|---|
| Contraseña del admin SQL | La pide Azure CLI al desplegar → **solo** el servidor SQL (acceso de emergencia) | Repositorio, archivos de parámetros, historial de la consola **y, desde la Fase 3B, la Function App** |
| Identidad administrada de la Function | Microsoft Entra ID (la crea y la borra Azure con la Function). Entra en SQL con un token de ~1 hora | No hay nada que guardar: no tiene contraseña |
| Administrador de Entra del servidor SQL | Tu usuario. Su Object ID lo pasa `desplegar.ps1` (o el secreto `SQL_ADMIN_ENTRA_ID`) | Repositorio |
| Clave de la Storage Account | La lee el Bicep (`listKeys()`) → configuración de la Function App | Repositorio |
| Clave de la función HTTP | La genera Azure; se consulta con `az functionapp function keys list` | Repositorio |

```
 Function App ──(identidad administrada: token)──> Azure SQL  [usuario func-agroeco-dev-XXXXX, permisos mínimos]
 Function App ──(clave de la cuenta)─────────────> Storage    [sin cambios en la Fase 3B]
```

El Storage sigue con la clave de la cuenta. Pasarlo a identidad exigiría asignaciones de roles de Azure (RBAC);
ver [`identidad_sql.md`](identidad_sql.md#-hacen-falta-asignaciones-de-roles).

## 🚚 Dos formas de desplegar (Fase 2)

| | Desde tu ordenador | Desde GitHub Actions |
|---|---|---|
| Script | `scripts/desplegar.ps1` / `.sh` | `.github/workflows/desplegar.yml` |
| Plantilla | `infra/main.bicep` (suscripción: crea el grupo) | `infra/modulos/recursos.bicep` (directamente en el grupo) |
| Identidad | Tu usuario (`az login`) | Aplicación de Entra ID con OIDC, rol Contributor solo sobre `rg-agroeco-dev` |
| Cuándo | El primer despliegue, o después de `borrar_todo` | Cada `push` a `main` |

Las dos usan el mismo módulo y calculan el sufijo dentro de `recursos.bicep`, así que los nombres son idénticos.
Detalles en [`cicd_oidc.md`](cicd_oidc.md).
