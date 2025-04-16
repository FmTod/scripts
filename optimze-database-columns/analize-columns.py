import csv
import json
import logging
import pymysql
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import List, Dict, Optional, Tuple
from datetime import datetime
from pymysql import Error

# Configurar logging
logging.basicConfig(
	level=logging.INFO,
	format='%(asctime)s - %(levelname)s - %(message)s',
	handlers=[
		logging.FileHandler('schema_analyzer.log'),
		logging.StreamHandler()
	]
)
logger = logging.getLogger(__name__)


class MariaDBSchemaOptimizer:
	def __init__(self, config_file: str = 'config.json'):
		"""Inicializa el analizador con configuración desde archivo JSON"""
		self.config = self.load_config(config_file)
		self.excluded_dbs = ['information_schema', 'performance_schema', 'mysql', 'sys']
		
		# Configurar nivel de logging
		log_level = getattr(logging, self.config.get('log_level', 'INFO').upper())
		logger.setLevel(log_level)
		
		logger.info("Inicializando MariaDBSchemaOptimizer")
	
	def load_config(self, config_file: str) -> Dict:
		"""Carga la configuración desde archivo JSON"""
		try:
			with open(config_file, 'r') as f:
				config = json.load(f)
				
				# Validar configuración mínima requerida
				required_keys = ['host', 'user', 'central_db']
				if not all(key in config for key in required_keys):
					raise ValueError(f"Configuración incompleta. Requerido: {required_keys}")
				
				return config
		except Exception as e:
			logger.error(f"Error al cargar configuración: {e}")
			raise
	
	def get_connection(self, database: Optional[str] = None) -> pymysql.Connection:
		"""Establece conexión con la base de datos especificada"""
		try:
			# para linux:
			
			conn = pymysql.connect(
				unix_socket="/var/run/mysqld/mysqld.sock",  # Ruta del socket
				user=self.config['user'],
				password=self.config.get('password'),
				database=database,
				charset='utf8mb4',
				cursorclass=pymysql.cursors.DictCursor,
				connect_timeout=10
			)
			return conn
		except Error as e:
			logger.error(f"Error al conectar a {database if database else 'servidor'}: {e}")
			raise
	
	def get_all_databases(self) -> List[str]:
		"""Obtiene lista de todas las bases de datos (central y tenants)"""
		conn = None
		try:
			conn = self.get_connection()
			with conn.cursor() as cursor:
				cursor.execute("SHOW DATABASES")
				dbs = [row['Database'] for row in cursor.fetchall()]
				
				# Filtrar bases de datos relevantes
				db_pattern = self.config.get('tenant_db_pattern', 'tenant_1')
				central_and_tenants = [db for db in dbs 
									 if db not in self.excluded_dbs and 
									 (db == self.config['central_db'] or 
									  db.startswith(db_pattern.split('%')[0]))]
				
				logger.info(f"Encontradas {len(central_and_tenants)} bases de datos para analizar")
				return central_and_tenants
		except Exception as e:
			logger.error(f"Error al obtener listado de bases de datos: {e}")
			raise
		finally:
			if conn:
				conn.close()
	
	def analyze_database(self, database: str) -> List[Dict]:
		"""Analiza una base de datos individual"""
		conn = None
		schema_info = []
		
		try:
			logger.info(f"Analizando base de datos: {database}")
			conn = self.get_connection(database)
			
			with conn.cursor() as cursor:
				# Obtener todas las tablas
				cursor.execute(f"SHOW TABLES")
				tables = [row[f"Tables_in_{database}"] for row in cursor.fetchall()]
				
				for table in tables:
					logger.debug(f"Procesando tabla: {table}")
					
					# Obtener información de columnas
					cursor.execute(f"""
						SELECT column_name, data_type, character_maximum_length, 
							   numeric_precision, numeric_scale, is_nullable, column_default
						FROM information_schema.columns 
						WHERE table_schema = %s AND table_name = %s
					""", (database, table))
					columns = cursor.fetchall()
					
					for column in columns:
						try:
							max_length = self.get_column_max_length(conn, table, column)
							optimized_type = self.suggest_optimized_type(column, max_length)
							
							schema_info.append({
								'database': database,
								'table': table,
								'column': column['column_name'],
								'current_type': column['data_type'],
								'max_length': max_length,
								'is_nullable': column['is_nullable'],
								'has_default': column['column_default'] is not None,
								'optimized_type': optimized_type,
								'analysis_time': datetime.now().isoformat()
							})
						except Exception as e:
							logger.error(f"Error procesando columna {table}.{column['column_name']}: {e}")
							continue
			
			return schema_info
		except Exception as e:
			logger.error(f"Error al analizar base de datos {database}: {e}")
			return []
		finally:
			if conn:
				conn.close()
	
	def get_column_max_length(self, conn: pymysql.Connection, table: str, column: Dict) -> Optional[int]:
	    """Calcula la longitud máxima de los datos en una columna específica"""
	    try:
	        with conn.cursor() as cursor:
	            col_name = column['column_name']
	            data_type = column['data_type'].lower()
	            
	            # Seguridad para evitar inyecciones SQL
	            safe_col = column['column_name']
	            safe_table = table
	            
	            # Determinamos la consulta según el tipo de dato
	            if 'varchar' in data_type or 'text' in data_type:
	                query = f"""
	                    SELECT MAX(
	                        CASE 
	                            WHEN {safe_col} IS NULL THEN NULL
	                            ELSE CHAR_LENGTH({safe_col})
	                        END
	                    ) AS max_len 
	                    FROM {safe_table}
	                """
	            elif 'blob' in data_type:
	                query = f"""
	                    SELECT MAX(
	                        CASE 
	                            WHEN {safe_col} IS NULL THEN NULL
	                            ELSE LENGTH({safe_col})
	                        END
	                    ) AS max_len 
	                    FROM {safe_table}
	                """
	            elif 'int' in data_type or 'decimal' in data_type:
	                query = f"""
	                    SELECT MAX(
	                        CASE 
	                            WHEN {safe_col} IS NULL THEN NULL
	                            ELSE CHAR_LENGTH(CAST({safe_col} AS CHAR))
	                        END
	                    ) AS max_len 
	                    FROM {safe_table}
	                """
	            elif 'date' in data_type or 'datetime' in data_type or 'timestamp' in data_type:
	                query = f"""
	                    SELECT MAX(
	                        CASE 
	                            WHEN {safe_col} IS NULL THEN NULL
	                            ELSE CHAR_LENGTH(CAST({safe_col} AS CHAR))
	                        END
	                    ) AS max_len 
	                    FROM {safe_table}
	                """
	            elif 'enum' in data_type or 'set' in data_type:
	                query = f"""
	                    SELECT MAX(
	                        CASE 
	                            WHEN {safe_col} IS NULL THEN NULL
	                            ELSE CHAR_LENGTH({safe_col})
	                        END
	                    ) AS max_len 
	                    FROM {safe_table}
	                """
	            else:
	                # Para cualquier otro tipo que no esté cubierto, usamos una consulta genérica
	                query = f"""
	                    SELECT MAX(
	                        CASE 
	                            WHEN {safe_col} IS NULL THEN NULL
	                            ELSE CHAR_LENGTH(CAST({safe_col} AS CHAR))
	                        END
	                    ) AS max_len 
	                    FROM {safe_table}
	                """
	            
	            cursor.execute(query)
	            result = cursor.fetchone()
	            return result['max_len'] if result else None

	    except Exception as e:
	        logger.error(f"Error al obtener longitud máxima para {table}.{col_name}: {e}")
	        return None

	
	def suggest_optimized_type(self, column: Dict, max_length: Optional[int]) -> str:
		"""Sugiere un tipo de dato optimizado basado en el uso actual"""
		data_type = column['data_type'].lower()
		char_max_length = column['character_maximum_length']
		num_precision = column['numeric_precision']
		num_scale = column['numeric_scale']
		
		# Para tipos de texto
		if data_type in ('varchar', 'char'):
			if max_length is None:
				return data_type + (f"({char_max_length})" if char_max_length else "")
			
			if max_length <= 8 and data_type == 'varchar':
				return f"CHAR({max_length})"
			elif max_length <= 255:
				return f"VARCHAR({max_length})"
			elif max_length <= 65535:
				return "TEXT"
			elif max_length <= 16777215:
				return "MEDIUMTEXT"
			else:
				return "LONGTEXT"
		
		# Para tipos numéricos
		elif data_type in ('int', 'bigint', 'smallint', 'tinyint'):
			if max_length is None:
				return data_type
			
			if data_type == 'int' and max_length < 5:
				return "SMALLINT"
			elif data_type == 'int' and max_length < 3:
				return "TINYINT"
			elif data_type == 'bigint' and max_length < 10:
				return "INT"
			else:
				return data_type
		
		# Para tipos decimal
		elif data_type == 'decimal':
			if num_precision and num_scale:
				return f"DECIMAL({num_precision},{num_scale})"
			else:
				return "DECIMAL(10,2)"
		
		# Para tipos fecha/hora
		elif data_type in ('datetime', 'timestamp'):
			return data_type
		
		# Para otros tipos, mantener igual
		else:
			return data_type
	
	def analyze_all_databases_parallel(self, max_workers: int = 5) -> List[Dict]:
		"""Analiza todas las bases de datos en paralelo"""
		databases = self.get_all_databases()
		all_schema_info = []
		
		logger.info(f"Iniciando análisis paralelo con {max_workers} workers")
		
		with ThreadPoolExecutor(max_workers=max_workers) as executor:
			futures = {executor.submit(self.analyze_database, db): db for db in databases}
			
			for future in as_completed(futures):
				db = futures[future]
				try:
					result = future.result()
					if result:
						all_schema_info.extend(result)
						logger.info(f"Completado análisis de {db} ({len(result)} columnas)")
				except Exception as e:
					logger.error(f"Error en análisis de {db}: {e}")
		
		logger.info(f"Análisis completado. Total de columnas procesadas: {len(all_schema_info)}")
		return all_schema_info
	
	def generate_optimization_report(self, data: List[Dict], output_file: str):
		"""Genera un reporte CSV con recomendaciones de optimización"""
		if not data:
			logger.warning("No hay datos para generar el reporte")
			return
		
		try:
			with open(output_file, 'w', newline='', encoding='utf-8') as csvfile:
				fieldnames = [
					'database', 'table', 'column', 'current_type', 
					'max_length', 'is_nullable', 'has_default',
					'optimized_type', 'analysis_time'
				]
				
				writer = csv.DictWriter(csvfile, fieldnames=fieldnames)
				writer.writeheader()
				
				for row in data:
					writer.writerow(row)
			
			logger.info(f"Reporte generado exitosamente: {output_file}")
			
			# Generar resumen estadístico
			self.generate_summary_report(data, output_file.replace('.csv', '_summary.txt'))
		except Exception as e:
			logger.error(f"Error al generar reporte CSV: {e}")
			raise
	
	def generate_summary_report(self, data: List[Dict], output_file: str):
		"""Genera un reporte resumen con estadísticas"""
		try:
			optimizations = sum(1 for row in data if row['optimized_type'].lower() != row['current_type'].lower())
			total_columns = len(data)
			
			with open(output_file, 'w') as f:
				f.write(f"Resumen de Optimización de Esquema\n")
				f.write(f"Fecha: {datetime.now().isoformat()}\n")
				f.write(f"\n")
				f.write(f"Total de bases de datos analizadas: {len({row['database'] for row in data})}\n")
				f.write(f"Total de tablas analizadas: {len({(row['database'], row['table']) for row in data})}\n")
				f.write(f"Total de columnas analizadas: {total_columns}\n")
				f.write(f"Columnas con sugerencia de optimización: {optimizations} ({optimizations/total_columns:.1%})\n")
				f.write(f"\n")
				f.write(f"Recomendaciones:\n")
				f.write(f"- Columnas con optimizaciones sugeridas deben ser evaluadas cuidadosamente\n")
				f.write(f"- Considerar impacto en aplicaciones antes de realizar cambios\n")
				f.write(f"- Realizar cambios en un entorno de pruebas primero\n")
			
			logger.info(f"Reporte resumen generado: {output_file}")
		except Exception as e:
			logger.error(f"Error al generar reporte resumen: {e}")

if __name__ == "__main__":
	try:
		logger.info("Iniciando análisis de esquemas MariaDB")
		
		# Inicializar optimizador
		optimizer = MariaDBSchemaOptimizer('config.json')
		
		# Realizar análisis en paralelo
		schema_data = optimizer.analyze_all_databases_parallel(
			max_workers=optimizer.config.get('max_workers', 5)
		)
		
		# Generar reporte
		output_file = optimizer.config.get('output_file', 'schema_optimization_report.csv')
		optimizer.generate_optimization_report(schema_data, output_file)
		
		logger.info("Proceso completado exitosamente")
	except Exception as e:
		logger.error(f"Error en el proceso principal: {e}")
		raise
