<?xml version="1.0" encoding="UTF-8"?>
<!--
  Heat transform: mark every harvested component 64-bit.
  Heat generates 32-bit components by default; installing them into
  ProgramFiles64Folder violates ICE80 ("32BitComponent uses
  64BitDirectory"). Applied via heat -t (see windows-installer.yml).
  Identity transform otherwise — every other node passes through unchanged.
-->
<xsl:stylesheet version="1.0"
  xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
  xmlns:wix="http://schemas.microsoft.com/wix/2006/wi">
  <xsl:output method="xml" indent="yes" />
  <xsl:template match="@*|node()">
    <xsl:copy>
      <xsl:apply-templates select="@*|node()" />
    </xsl:copy>
  </xsl:template>
  <xsl:template match="wix:Component">
    <xsl:copy>
      <xsl:apply-templates select="@*" />
      <xsl:attribute name="Win64">yes</xsl:attribute>
      <xsl:apply-templates select="node()" />
    </xsl:copy>
  </xsl:template>
</xsl:stylesheet>
