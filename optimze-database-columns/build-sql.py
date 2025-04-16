import csv
from typing import List, Dict
from pathlib import Path


def generate_alter_queries(csv_path: str) -> List[str]:
    """
    Genera consultas ALTER TABLE a partir de un archivo CSV con recomendaciones de optimización de esquema.
    """
    queries = []

    try:
        with open(csv_path, mode="r", encoding="utf-8") as csv_file:
            csv_reader = csv.DictReader(csv_file)

            for row in csv_reader:
                # Validación y extracción segura de datos
                try:
                    db = row.get("database", "").strip()
                    tbl = row.get("table", "").strip()
                    col = row.get("column", "").strip()
                    current = row.get("current_type", "").strip()
                    optimized = row.get("optimized_type", "").strip()

                    if not all([db, tbl, col, current, optimized]):
                        raise ValueError("Faltan valores requeridos en alguna columna")

                    # Construcción CORRECTA de la consulta
                    alter_query = (
                        f"-- Cambio recomendado para {db}.{tbl}.{col}\n"
                        f"-- Tipo actual: {current} | Tipo sugerido: {optimized}\n"
                        f"ALTER TABLE {db}.{tbl} MODIFY COLUMN {col} {optimized};\n\n"
                    )

                    queries.append(alter_query)

                except Exception as e:
                    print(f"Error procesando fila: {str(e)}")
                    continue

        return queries

    except FileNotFoundError:
        raise FileNotFoundError(f"Archivo no encontrado: {csv_path}")
    except Exception as e:
        raise Exception(f"Error al procesar CSV: {str(e)}")


def save_queries_to_file(queries: List[str], output_path: str) -> None:
    """
    Guarda las consultas generadas en un archivo SQL.

    Args:
        queries (List[str]): Lista de consultas SQL a guardar.
        output_path (str): Ruta donde se guardará el archivo SQL.
    """
    try:
        with open(output_path, "w", encoding="utf-8") as sql_file:
            sql_file.write(
                "-- Script generado automáticamente para optimización de esquema\n"
            )
            sql_file.write(
                "-- Tipos de datos actuales se muestran como comentarios\n\n"
            )
            sql_file.writelines(queries)
    except Exception as e:
        raise Exception(f"Error al guardar el archivo SQL: {str(e)}")


def main():
    # Configuración de rutas
    input_csv = "schema_optimization_report.csv"
    output_sql = "schema_optimization_queries.sql"

    try:
        print(f"Procesando archivo CSV: {input_csv}")

        # Generar consultas
        queries = generate_alter_queries(input_csv)

        # Guardar consultas en archivo SQL
        save_queries_to_file(queries, output_sql)

        print(f"¡Proceso completado con éxito!")
        print(f"Se generaron {len(queries)} consultas ALTER TABLE.")
        print(f"Consultas guardadas en: {output_sql}")

    except Exception as e:
        print(f"Error durante el proceso: {str(e)}")
        return 1

    return 0


if __name__ == "__main__":
    main()
