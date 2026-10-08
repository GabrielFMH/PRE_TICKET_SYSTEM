# Flujo preticket TFS

Script de consola para Azure DevOps Server (TFS). A partir del nombre de un ticket crea el User Story, abre un buscador de repositorios y, en los que elijas, crea la rama y la clona en local.

Ejemplo de entrada:

```text
2026_03467A_AB Subida de archivos desembolso
```

- User Story: `2026_03467A_AB Subida de archivos desembolso`
- Rama: `2026_03467A_AB`
- Descarga: `{LocalRoot}\2026_03467A_AB\NombreDelRepo`

## Requisitos

- Windows PowerShell 5.1 o PowerShell 7
- Git en el PATH
- Acceso a la colección de Azure DevOps Server, con permiso para crear work items, ramas y clonar

## Configuración

Edita [config.ps1](config.ps1) antes de ejecutarlo. Estas variables son obligatorias:

| Variable | Uso |
| --- | --- |
| `TfsBaseUrl` | URL del servidor, sin la colección. Ejemplo: `http://tfs.local:8080/tfs` |
| `Collection` | Nombre de la colección. Ejemplo: `DefaultCollection` |
| `WorkItemProject` | Proyecto donde se crea el User Story. Los repos pueden estar en otros proyectos. |
| `LocalRoot` | Carpeta base de las descargas. Ejemplo: `C:\repos\tickets` |

Opcionales:

| Variable | Uso |
| --- | --- |
| `Pat` | Personal Access Token. Vacío: usa la sesión de Windows. |
| `WorkItemType` | Por defecto `User Story`. En Scrum usa `Product Backlog Item`. |
| `ApiVersion` | Por defecto `6.0`. |
| `SourceBranch` | Rama origen. Vacío: la rama por defecto de cada repositorio. Ejemplo: `develop`. |

Si `Pat` tiene valor, no subas `config.ps1` a un repositorio público.

## Ejecución

Desde esta carpeta:

```powershell
powershell -ExecutionPolicy Bypass -File .\Start-PreTicket.ps1
```

El script se detiene si falta `TfsBaseUrl`, `Collection`, `WorkItemProject` o `LocalRoot`.

## Qué hace

1. Lista los proyectos de la colección y los repositorios Git de cada uno.
2. Pide el nombre del ticket. El primer texto es el código de la rama y de la carpeta. El texto completo es el título del User Story.
3. Crea el work item en `WorkItemProject` y muestra su id.
4. Abre el selector:
   - Escribe parte del nombre del repo o del proyecto. Vacío muestra todos.
   - Elige varios con números separados por coma, por ejemplo `1,3,5`.
   - Puedes buscar otra vez y sumar repos.
   - Escribe `listo` y confirma con `s`.
5. En cada repo crea `refs/heads/2026_03467A_AB` desde la rama origen. Si la rama ya existe, no la vuelve a crear y sigue con la descarga.
6. Clona solo esa rama.

Si cancelas después de crear el User Story, el work item queda creado y no se crean ramas.

## Carpetas

```text
C:\repos\tickets\2026_03467A_AB\SistemaPagos
C:\repos\tickets\2026_03467A_AB\SistemaClientes
```

Si dos repos de proyectos distintos tienen el mismo nombre, la carpeta pasa a ser `Proyecto__Repo`. Si la carpeta ya existe, no la sobrescribe.

## Resultado

Al terminar imprime el id del User Story, si la rama se creó o ya existía, y la ruta local de cada clone. Si algún repo falla, el resto continúa y el script termina con código 1.
