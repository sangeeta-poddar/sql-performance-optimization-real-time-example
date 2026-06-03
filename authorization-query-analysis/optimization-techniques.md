## Dashboard stored procedure optimization
#### Scenario
The Dashboard Request calls the main stored procedure GetDashboardCases. This file includes the optimization approach for GetDashboardCases. 

### 1.	Nested procedure calls
GetDashboardCases calls a nested procedure GetAuthCaseListByUser. The optimization for GetAuthCaseListByUser is included in the same reporditory under the folder authorization-query-analysis.

### 2.	Eliminate subqueries
Eliminated the subquery to return TotalDocs. Instead we used derived table.
```sql
-- before optimization
SELECT mc.MedicalCaseId,
  cpd.PrimaryPhysicianId,
  CONCAT_WS(' ', concat(TU.LastName, ','), TU.FirstName, TU.MiddleName ) AS PrimaryPhysicianName ,
  cpd.EventDatetime,
  mc.CaseStatusId,
  (select CaseStatusName from LK_CaseStatus where CaseStatusId = mc.CaseStatusId) AS CaseStatus,
  p.patientid,
  CONCAT_WS(' ', concat(p.lastname, ','), p.firstname, p.middlename) AS patientfullname,
  p.DOB AS PatientDOB,
  TotalDocs = (select count(documentId) from DocCaseMapping where MedicalCaseId = mc.caseId and IsActive = 1),
  cpd.OrganizationId,
  org.OrganizationName AS ClinicName
FROM MedicalCases mc
INNER JOIN @AuthCaseList ac ON mc.MedicalCaseId = ac.MedicalCaseId
INNER JOIN CasePlanningDetails cpd ON mc.MedicalCaseId = cpd.MedicalCaseId
INNER JOIN Patients p ON mc.patientid = p.patientid
INNER JOIN Users u ON cpd.PrimaryphysicianId = u.UserId 
INNER JOIN Organizations org ON cpd.OrganizationId = org.OrganizationId
LEFT JOIN @CaseValidationStatus cvd ON cpd.MedicalCaseId = cvd.MedicalCaseId;

-- after optimization
SELECT mc.MedicalCaseId,
  cpd.PrimaryPhysicianId,
  CONCAT_WS(' ', concat(TU.LastName, ','), TU.FirstName, TU.MiddleName ) AS PrimaryPhysicianName ,
  cpd.EventDatetime,
  mc.CaseStatusId,
  lcs.CaseStatusName AS CaseStatus,
  p.PatientId,
  CONCAT_WS(' ', concat(pp.lastname, ','), pp.firstname, pp.middlename) AS patientfullname,
  p.dateofbirth AS PatientDOB,
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
```
### 3. Data Reduction Strategy
Passed the input filter values to the nested stored procedure to apply early filtering techniques to minimize row processing. Prepare a json with the relevant filter values and pass it to the nested procedure so that the filter can be applied there before returning the data to the main procedure. In this way the main procedure can work with a smaller set of data.
```sql
-- before optimization

--Get authrorized medical cases
	INSERT INTO @AuthCaseList
	EXEC USP_GetAuthCaseListByUser
		@StartDate = @StartDate,
		@EndDate = @EndDate,
		@UserId = @UserId, 
		@FilterValues = NULL

	SELECT mc.MedicalCaseId,
		.
		.
	FROM MedicalCases mc
	INNER JOIN @AuthCaseList ac ON mc.MedicalCaseId = ac.MedicalCaseId
		.
		.
	WHERE  
		( @StartDate IS NULL OR CAST(cpd.EventDatetime AS DATE) >= @StartDate ) AND 
		( @EndDate IS NULL OR CAST(cpd.EventDatetime AS DATE) <= @EndDate ) AND 
		( @CaseStatusId IS NULL OR mc.CaseStatusId = @CaseStatusId ) AND 
		( @PatientName IS NULL OR CONCAT_WS(' ', p.firstname, p.middlename, p.lastname) LIKE'%' + @PatientName + '%') AND
		( @PatientDOB IS NULL OR p.dateofbirth = @PatientDOB ) AND 
		( @OrganizationId IS NULL OR cpd.OrganizationId = @OrganizationId ) AND 
		( @PrimaryPhysicianId IS NULL OR cpd.primarysurgeonid = @PrimaryPhysicianId ) AND 
		( @MedicalCaseId IS NULL OR mc.MedicalCaseId = @MedicalCaseId )

-- after optimization
	SET @FilterValues = ''

	IF(@HOSPITAL IS NOT NULL)
		SET @FilterValues = @FilterValues+',{"Field":"Organization","Values":["'+@OrganizationIdName+'"]}'

	IF(@PRIMARYphysicianID IS NOT NULL)
		SET @FilterValues = @FilterValues+',{"Field":"PrimaryPhysician","Values":["'+@PrimaryPhysicianId+'"]}'

	IF(@MedicalCaseId IS NOT NULL)
		SET @FilterValues = CONCAT(@FilterValues, ',{"Field":"MedicalCaseId","Values":["', @MedicalCaseId, '"]}')

	IF @FilterValues != ''
		SET @FilterValues = STUFF(@FilterValues, 1, 1, '[') + ']'
	ELSE 
		SET @FilterValues = '[]'

  --Get authrorized medical cases
	INSERT INTO @AuthCaseList
	EXEC USP_GetAuthCaseListByUser
		@StartDate = @StartDate,
		@EndDate = @EndDate,
		@UserId = @UserId, 
		@FilterValues = @FilterValues

