# Completa estos valores antes de ejecutar Start-PreTicket.ps1.
# No guardes este archivo en un repositorio público si contiene un PAT.

# URL del Azure DevOps Server / TFS, sin la colección.
# Ejemplo: http://tfs.local:8080/tfs
$TfsBaseUrl = ""

# Nombre de la colección.
# Ejemplo: DefaultCollection
$Collection = ""

# Personal Access Token. Déjalo vacío para usar la sesión de Windows.
$Pat = ""

# Proyecto donde se crea el User Story.
# Los repositorios pueden vivir en otros proyectos de la misma colección.
$WorkItemProject = ""

# Tipo de work item. En un proceso Scrum usa "Product Backlog Item".
$WorkItemType = "User Story"

# Carpeta local donde se clonan las ramas.
# Ejemplo: C:\repos\tickets
# Resultado: {LocalRoot}\2026_03467A_AB\NombreDelRepo
$LocalRoot = ""

# Versión de la API REST de Azure DevOps Server.
$ApiVersion = "6.0"

# Rama origen. Vacío = rama por defecto de cada repositorio.
# Ejemplo: develop
$SourceBranch = ""
