/* =====================================================================
   BASE DE DATOS II - PROYECTO FINAL TEMA 3
   ---------------------------------------------------------------------
   SCRIPT 00 : EJECUTA TODA LA CONSTRUCCION EN ORDEN (scripts 01 a 08)
   COMO USARLO EN SSMS:
     1. Menu Consulta (Query) -> activar "Modo SQLCMD" (SQLCMD Mode).
     2. Ajustar la variable RUTA a la carpeta donde estan los scripts.
     3. Ejecutar (F5).
   Luego ejecutar manualmente 09_Consultas.sql y 10_Pruebas_Evidencias.sql
   para obtener las evidencias.
   ===================================================================== */
:setvar RUTA "D:\Documents\ProyectoFinal_BD2\scripts"
:on error exit

PRINT N'===== 01 Bases de datos remotas (5 sucursales) =====';
:r $(RUTA)\01_BD_Remotas_Sucursales.sql
PRINT N'===== 02 Base de datos principal =====';
:r $(RUTA)\02_BD_Principal.sql
PRINT N'===== 03 Linked Servers =====';
:r $(RUTA)\03_Linked_Server.sql
PRINT N'===== 04 Funciones =====';
:r $(RUTA)\04_Funciones.sql
PRINT N'===== 05 Triggers =====';
:r $(RUTA)\05_Triggers.sql
PRINT N'===== 06 Procedimientos =====';
:r $(RUTA)\06_Procedimientos.sql
PRINT N'===== 07 Vistas =====';
:r $(RUTA)\07_Vistas.sql
PRINT N'===== 08 Datos =====';
:r $(RUTA)\08_Datos_Principal.sql
PRINT N'===== CONSTRUCCION FINALIZADA =====';
