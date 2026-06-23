"""
C-31+ v21-wsfe-production-hardening — Dependency declarations (Hueco 5).

TDD RED->GREEN->TRIANGULATE: verifica que `supabase` esta declarado en
backend/requirements.txt y en backend/pyproject.toml, y que `zeep` no
fue duplicado.

Gate CI: python -m pytest backend/tests -m "not integration"
Spec ref: openspec/changes/v21-wsfe-production-hardening/specs/afip-fiscal-document/spec.md
  Requirement: Dependencia supabase-py declarada
Design ref: D6
"""
from __future__ import annotations

import re
from pathlib import Path

import pytest

# Rutas relativas a la raiz del repo desde este test (tests/ vive dentro de backend/)
_BACKEND_DIR = Path(__file__).parent.parent  # backend/
_REQUIREMENTS_TXT = _BACKEND_DIR / "requirements.txt"
_PYPROJECT_TOML   = _BACKEND_DIR / "pyproject.toml"


def _get_pyproject_dep_block() -> str:
    """Extract the [project] dependencies block from pyproject.toml.

    Handles brackets inside dependency specs like uvicorn[standard] by
    finding the list start and scanning for the matching closing bracket.
    """
    content = _PYPROJECT_TOML.read_text(encoding="utf-8")
    # Find '[project]' section header
    proj_match = re.search(r'^\[project\]\s*$', content, re.MULTILINE)
    assert proj_match, "No se encontro [project] en pyproject.toml"
    proj_start = proj_match.end()
    # Within the project section, find 'dependencies = ['
    dep_start_match = re.search(r'dependencies\s*=\s*\[', content[proj_start:])
    assert dep_start_match, "No se encontro 'dependencies = [' en [project]"
    list_start = proj_start + dep_start_match.end()  # position after '['
    # Scan for the matching ']' counting nested brackets
    depth = 1
    pos = list_start
    while pos < len(content) and depth > 0:
        if content[pos] == '[':
            depth += 1
        elif content[pos] == ']':
            depth -= 1
        pos += 1
    return content[list_start : pos - 1]


class TestSupabaseDependencyDeclared:
    """1.1 RED -> 1.2 GREEN: supabase declarado en ambos archivos de dependencias."""

    def test_supabase_in_requirements_txt(self):
        """1.1 RED: `supabase` aparece en backend/requirements.txt (falla antes de 1.2)."""
        content = _REQUIREMENTS_TXT.read_text(encoding="utf-8")
        lines = content.splitlines()
        supabase_lines = [l.strip() for l in lines if re.match(r"^supabase\b", l.strip())]
        assert supabase_lines, (
            f"'supabase' no encontrado en {_REQUIREMENTS_TXT}. "
            "Agregar: supabase>=2.0"
        )

    def test_supabase_in_pyproject_toml_dependencies(self):
        """1.1 RED: `supabase` aparece en la seccion [project] dependencies de pyproject.toml."""
        dep_block = _get_pyproject_dep_block()
        supabase_entries = [
            l.strip()
            for l in dep_block.splitlines()
            if re.search(r'"supabase\b', l) or re.search(r"'supabase\b", l)
        ]
        assert supabase_entries, (
            f"'supabase' no encontrado en [project] dependencies de {_PYPROJECT_TOML}. "
            'Agregar: "supabase>=2.0",'
        )


class TestNoDuplicatedDependencies:
    """1.3 TRIANGULATE: zeep no duplicado, supabase no duplicado."""

    def test_zeep_not_duplicated_in_requirements_txt(self):
        """1.3 TRIANGULATE: zeep aparece exactamente una vez en requirements.txt."""
        content = _REQUIREMENTS_TXT.read_text(encoding="utf-8")
        zeep_lines = [l.strip() for l in content.splitlines() if re.match(r"^zeep\b", l.strip())]
        assert len(zeep_lines) == 1, (
            f"zeep debe aparecer exactamente 1 vez en requirements.txt; "
            f"encontrado {len(zeep_lines)}: {zeep_lines}"
        )

    def test_zeep_not_duplicated_in_pyproject_toml(self):
        """1.3 TRIANGULATE: zeep aparece exactamente una vez en pyproject.toml dependencies."""
        dep_block = _get_pyproject_dep_block()
        zeep_entries = [
            l for l in dep_block.splitlines()
            if re.search(r'"zeep\b', l) or re.search(r"'zeep\b", l)
        ]
        assert len(zeep_entries) == 1, (
            f"zeep debe aparecer exactamente 1 vez en pyproject.toml dependencies; "
            f"encontrado {len(zeep_entries)}: {zeep_entries}"
        )

    def test_supabase_not_duplicated_in_requirements_txt(self):
        """1.3 TRIANGULATE: supabase aparece exactamente una vez en requirements.txt."""
        content = _REQUIREMENTS_TXT.read_text(encoding="utf-8")
        supabase_lines = [l.strip() for l in content.splitlines() if re.match(r"^supabase\b", l.strip())]
        assert len(supabase_lines) == 1, (
            f"supabase debe aparecer exactamente 1 vez en requirements.txt; "
            f"encontrado {len(supabase_lines)}: {supabase_lines}"
        )

    def test_supabase_not_duplicated_in_pyproject_toml(self):
        """1.3 TRIANGULATE: supabase aparece exactamente una vez en pyproject.toml dependencies."""
        dep_block = _get_pyproject_dep_block()
        supabase_entries = [
            l for l in dep_block.splitlines()
            if re.search(r'"supabase\b', l) or re.search(r"'supabase\b", l)
        ]
        assert len(supabase_entries) == 1, (
            f"supabase debe aparecer exactamente 1 vez en pyproject.toml dependencies; "
            f"encontrado {len(supabase_entries)}: {supabase_entries}"
        )
