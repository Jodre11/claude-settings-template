---
name: Use office skills for office files
description: Prefer office-docx/xlsx/pptx/pdf skills over Python scripts when working with Office documents
type: feedback
originSessionId: aafcc8d4-373e-4ffc-923c-5dda38f6d0d4
---
Use the office-* skills (office-docx, office-xlsx, office-pptx, office-pdf) when working with Office files.

**Why:** Claude has a tendency to reach for Python (openpyxl, python-docx, etc.) when asked to work with Office documents. The user has installed dedicated skills for this purpose and considers the Python approach suboptimal.

**How to apply:** When the task involves reading, creating, or editing .docx, .xlsx, .pptx, or .pdf files, invoke the corresponding office-* skill first. Only fall back to Python if the skill genuinely cannot handle the specific requirement.
