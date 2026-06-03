CREATE   PROCEDURE [dbo].[GetDashboardCases]
		@StartDate DATE,
		@EndDate DATE,
		@PatientName VARCHAR(MAX),
		@PatientDOB DATE,
		@OrganizationIdName VARCHAR(MAX),
		@PrimaryPhysicianId VARCHAR(MAX),
		@CaseStatusId INT,
		@MedicalCaseId INT,
		@UserId NVARCHAR(50),
		@FilterValues NVARCHAR(MAX)

AS
BEGIN
	DECLARE @AuthCaseList TABLE (MedicalCaseId INT)
	SET @FilterValues = ''

	IF(@OrganizationIdName IS NOT NULL)
		SET @FilterValues = @FilterValues+',{"Field":"Organization","Values":["'+@OrganizationIdName+'"]}'

	IF(@PrimaryPhysicianId IS NOT NULL)
		SET @FilterValues = @FilterValues+',{"Field":"PrimaryPhysician","Values":["'+@PrimaryPhysicianId+'"]}'

	IF(@MedicalCaseId IS NOT NULL)
		SET @FilterValues = CONCAT(@FilterValues, ',{"Field":"MedicalCaseId","Values":["', @MedicalCaseId, '"]}')

	IF @FilterValues != ''
		SET @FilterValues = STUFF(@FilterValues, 1, 1, '[') + ']'
	ELSE 
		SET @FilterValues = '[]'

	--Get authrorized medical cases
	INSERT INTO @AuthCaseList
	EXEC GetAuthCaseListByUser
		@StartDate = @StartDate,
		@EndDate = @EndDate,
		@UserId = @UserId, 
		@FilterValues = @FilterValues

	SELECT mc.MedicalCaseId,
		cpd.PrimaryPhysicianId,
		CONCAT_WS(' ', concat(u.LastName, ','), u.FirstName, u.MiddleName ) AS PrimaryPhysicianName ,
		cpd.EventDatetime,
		mc.CaseStatusId,
		lcs.CaseStatusName AS CaseStatus,
		p.PatientId,
		CONCAT_WS(' ', concat(p.lastname, ','), p.firstname, p.middlename) AS patientfullname,
		p.DOB AS PatientDOB,
		ISNULL(dcm.TotalDocs, 0),
		cpd.OrganizationId,
		org.OrganizationName AS ClinicName
	FROM   MedicalCases mc
	INNER JOIN @AuthCaseList ac ON mc.MedicalCaseId = ac.MedicalCaseId
	INNER JOIN LK_CaseStatus lcs ON mc.CaseStatusId = lcs.CaseStatusId
	INNER JOIN CasePlanningDetails cpd ON mc.MedicalCaseId = cpd.MedicalCaseId
	INNER JOIN Patients p ON mc.patientid = p.patientid
	INNER JOIN Users u ON cpd.PrimaryPhysicianId = u.UserId 
	INNER JOIN Organizations org ON cpd.OrganizationId = org.OrganizationId
	LEFT JOIN (
		SELECT c.MedicalCaseId, COUNT(dcm.DocumentId) AS TotalDocs
		FROM @AuthCaseList c
		INNER JOIN DocCaseMapping dcm ON c.MedicalCaseId = dcm.MedicalCaseId AND dcm.IsActive = 1
		GROUP BY c.MedicalCaseId
	) dcm ON mc.MedicalCaseId = dcm.MedicalCaseId
	WHERE 
		( @PatientName IS NULL OR CONCAT_WS(' ', p.firstname, p.middlename, p.lastname) LIKE'%' + @PatientName + '%') AND
		( @PatientDOB IS NULL OR p.DOB = @PatientDOB )  
	ORDER  BY cpd.eventdatetime 

END

GO
