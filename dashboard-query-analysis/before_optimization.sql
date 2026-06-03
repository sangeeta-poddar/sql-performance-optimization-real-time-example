CREATE    PROCEDURE [dbo].[GetDashboardCases]
		@StartDate DATE,
		@EndDate DATE,
		@PatientName VARCHAR(50),
		@PatientDOB DATE,
		@OrganizationId VARCHAR(50),
		@PrimaryPhysicianId VARCHAR(50),
		@CaseStatusId INT,
		@MedicalCaseId INT,
		@UserId NVARCHAR(50),
		@FilterValues NVARCHAR(MAX)

AS
BEGIN
	DECLARE @AuthCaseList TABLE (MedicalCaseId INT)

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
		(select CaseStatusName from LK_CaseStatus where CaseStatusId = mc.CaseStatusId) AS CaseStatus,
		p.patientid,
		CONCAT_WS(' ', concat(p.lastname, ','), p.firstname, p.middlename) AS patientfullname,
		p.DOB AS PatientDOB,
		documentcount = (select count(documentId) from DocCaseMapping where MedicalCaseId = mc.MedicalCaseId and IsActive = 1),
		cpd.OrganizationId,
		org.OrganizationName AS ClinicName
	FROM MedicalCases mc
	INNER JOIN @AuthCaseList ac ON mc.MedicalCaseId = ac.MedicalCaseId
	INNER JOIN CasePlanningDetails cpd ON mc.MedicalCaseId = cpd.MedicalCaseId
	INNER JOIN Patients p ON mc.patientid = p.patientid
	INNER JOIN Users u ON cpd.PrimaryphysicianId = u.UserId 
	INNER JOIN Organizations org ON cpd.OrganizationId = org.OrganizationId
	WHERE  
		( @StartDate IS NULL OR CAST(cpd.EventDatetime AS DATE) >= @StartDate ) AND 
		( @EndDate IS NULL OR CAST(cpd.EventDatetime AS DATE) <= @EndDate ) AND 
		( @CaseStatusId IS NULL OR mc.CaseStatusId = @CaseStatusId ) AND 
		( @PatientName IS NULL OR CONCAT_WS(' ', p.firstname, p.middlename, p.lastname) LIKE'%' + @PatientName + '%') AND
		( @PatientDOB IS NULL OR p.DOB = @PatientDOB ) AND 
		( @OrganizationId IS NULL OR cpd.OrganizationId = @OrganizationId ) AND 
		( @PrimaryPhysicianId IS NULL OR cpd.PrimaryPhysicianId = @PrimaryPhysicianId ) AND 
		( @MedicalCaseId IS NULL OR mc.MedicalCaseId = @MedicalCaseId )
	ORDER  BY cpd.EventDatetime 

END

GO

